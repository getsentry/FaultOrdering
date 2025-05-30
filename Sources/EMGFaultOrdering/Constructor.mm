//
//  Constructor.mm
//  emergeFaultOrdering
//
//  Created by Noah Martin on 8/1/21.
//

#if defined(__arm64__) || defined(__aarch64__)

#import <Foundation/Foundation.h>
#import <vector>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/dyld_images.h>
#import <dlfcn.h>
#import <libgen.h>
#import <mach-o/getsect.h>
#import <os/log.h>
#import <sys/sysctl.h>
#include <SimpleDebugger.h>
#import "EMGObjCHelper.h"

bool parseFunctionStarts(const struct mach_header_64 *header, intptr_t slide, vm_address_t sectionStart, unsigned long sectionSize, void (*callback)(UInt64));

#define DYLD_INTERPOSE(_replacment,_replacee) \
   __attribute__((used)) static struct{ const void* replacment; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacment, (const void*)(unsigned long)&_replacee };

NSMutableArray<NSDictionary *> *loadedImages;
std::vector<uint64_t> *accessedAddresses;
NSObject *server;
SimpleDebugger *debugger;

kern_return_t my_task_set_exception_ports
(
  task_t task,
  exception_mask_t exception_mask,
  mach_port_t new_port,
  exception_behavior_t behavior,
  thread_state_flavor_t new_flavor
) {
  // Make sure there is no other exception port to handle EXC_MASK_BAD_ACCESS
  if ((exception_mask & EXC_MASK_BAD_ACCESS) == EXC_MASK_BAD_ACCESS) {
    // Remove EXC_MASK_BAD_ACCESS mask
    exception_mask &= ~EXC_MASK_BAD_ACCESS;
  }
  return task_set_exception_ports(task, exception_mask, new_port, behavior, new_flavor);
}
DYLD_INTERPOSE(my_task_set_exception_ports, task_set_exception_ports)

NSData* getAddresses() {
  NSMutableArray *arraySamples = [NSMutableArray new];
  for(uint64_t addr : *accessedAddresses) {
    [arraySamples addObject:@(addr)];
  }
  NSDictionary *result = @{
    @"loadedImages": loadedImages,
    @"addresses": arraySamples,
  };
  
  return [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
}

bool isDebuggerAttached() {
  const pid_t self = getpid();
  int mib[5] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, self, 0};

  auto proc = std::make_unique<struct kinfo_proc>();
  size_t proc_size = sizeof(struct kinfo_proc);
  if (sysctl(mib, 4, proc.get(), &proc_size, nullptr, 0) < 0) {
    printf("Error from sysctl\n");
    return false;
  }
  return proc->kp_proc.p_flag & P_TRACED;
}

void handleFunctionAddress(UInt64 addr) {
  debugger->setBreakpoint(addr);
}

void image_added(const struct mach_header* mh, intptr_t slide) {
  Dl_info info = {0};
  dladdr(mh, &info);
  NSString *path = @(info.dli_fname);
  [loadedImages addObject:@{
    @"path": path,
    @"slide": @(slide),
    @"loadAddress": @((__uint64_t ) mh),
  }];
  if (![path isEqualToString:[[NSBundle mainBundle] executablePath]]) {
    return;
  }

  const char *segname = "__TEXT";
  const char *sectname = "__text";
  unsigned long section_size = 0;
  vm_address_t section = (vm_address_t) getsectiondata((mach_header_64 *) mh, segname, sectname, &section_size);

  
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  NSString *documentsDirectory = [paths firstObject];
  NSString *filePath = [documentsDirectory stringByAppendingPathComponent:@"linkmap-addresses.json"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    NSArray *addresses = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    for (NSNumber *n in addresses) {
      handleFunctionAddress(slide + n.unsignedIntegerValue);
    }
  } else {
    NSLog(@"does not have linkmap");
    bool hasFunctionStarts = parseFunctionStarts((mach_header_64 *) mh, slide, section, section_size, &handleFunctionAddress);
    if (!hasFunctionStarts) {
      NSLog(@"No function starts, faults will not be measured");
    }
  }
}

void debuggerCallback(mach_port_t thread, arm_thread_state64_t state, std::function<void(bool removeBreak)> sendReply) {
    accessedAddresses->push_back(state.__pc);
    sendReply(true);
}

int readULEB128(const uint8_t *p, uint64_t *out) {
    uint64_t result = 0;
    int i = 0;

    do {
        uint8_t byte = *p & 0x7f;
        result |= (uint64_t)byte << (i * 7);
        i++;
    } while (*p++ & 0x80);

    *out = result;
    return i;
}

bool parseFunctionStarts(const struct mach_header_64 *header, intptr_t slide, vm_address_t sectionStart, unsigned long sectionSize, void (*callback)(UInt64)) {
  uintptr_t loadCommands = (uintptr_t)(header) + sizeof(struct mach_header_64);
  const struct segment_command_64 *textSegment = NULL;
  const struct segment_command_64 *linkeditSegment = NULL;
  const struct linkedit_data_command *funcStartsCommand = NULL;

  for (uint32_t i = 0; i < header->ncmds; i++) {
    const struct load_command *lc = (const struct load_command *)loadCommands;

    if (lc->cmd == LC_SEGMENT_64) {
      const struct segment_command_64 *segment = (struct segment_command_64 *)lc;
      if (strcmp(segment->segname, "__TEXT") == 0) {
        textSegment = segment;
      }
      if (strcmp(segment->segname, "__LINKEDIT") == 0) {
        linkeditSegment = segment;
      }
    } else if (lc->cmd == LC_FUNCTION_STARTS) {
      funcStartsCommand = (const struct linkedit_data_command *)lc;
    }
    loadCommands += lc->cmdsize;
  }

  if (!textSegment || !funcStartsCommand || !linkeditSegment) {
    return false;
  }

  uintptr_t linkeditVmStart = linkeditSegment->vmaddr + slide;
  const uint8_t *funcStartsData = (uint8_t *) (linkeditVmStart + (funcStartsCommand->dataoff - linkeditSegment->fileoff));
  uint32_t funcStartsSize = funcStartsCommand->datasize;
  uintptr_t addressFileOff = textSegment->fileoff;

  if (funcStartsSize == 0) {
    return false;
  }

  int i = 0;
  while(funcStartsData[i] != 0 && i < funcStartsSize) {
    uint64_t num = 0;
    i += readULEB128(funcStartsData + i, &num);
    addressFileOff += num;
    uintptr_t address = textSegment->vmaddr + (addressFileOff - textSegment->fileoff) + slide;
    if (address >= sectionStart && address < sectionStart + sectionSize) {
      // Disasembling aarch64 is actually much more complicated than this
      // but this heuristic seems to work to detect data in code
      auto word = *(uint32_t *)address;
      uint32_t opcode = word >> 24;
      if (opcode != 0) {
        callback(address);
      }
    }
  }
    return true;
}

__attribute__((constructor)) void setup(void);
__attribute__((constructor)) void setup() {
  const char *envValue = getenv("RUN_FAULT_ORDER");
  const char *envValueSetup = getenv("RUN_FAULT_ORDER_SETUP");
  bool isEnabled = envValue != NULL && strcmp(envValue, "1") == 0;
  bool isSetupEnabled = envValueSetup != NULL && strcmp(envValueSetup, "1") == 0;
  if (isSetupEnabled) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      // Run setup
      NSData *linkmapData = [NSData dataWithContentsOfURL:[NSURL URLWithString:@"http://localhost:38825/linkmap"]];
      if (linkmapData) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsDirectory = [paths firstObject];
        NSString *filePath = [documentsDirectory stringByAppendingPathComponent:@"linkmap-addresses.json"];
        [linkmapData writeToFile:filePath atomically:YES];
      } else {
        NSLog(@"Could not get linkmap data");
      }
    });
    return;
  } else if (!isEnabled) {
    NSLog(@"Fault ordering is not enabled");
    return;
  }

  loadedImages = [NSMutableArray new];
  accessedAddresses = new std::vector<uint64_t>();
  debugger = new SimpleDebugger();
  debugger->setExceptionCallback(debuggerCallback);
  debugger->startDebugging();

  // Add dyld load address since `_dyld_register_func_for_add_image` is not called for
  // dyld itself.
  struct task_dyld_info dyld_info;
  mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
  task_info(mach_task_self_, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count);
  struct dyld_all_image_infos *infos = (struct dyld_all_image_infos *)dyld_info.all_image_info_addr;
  void *header = (void *)infos->dyldImageLoadAddress;
  [loadedImages addObject:@{
    @"path": @"/usr/lib/dyld",
    @"slide": @((__uint64_t) header),
    @"loadAddress": @((__uint64_t) header),
  }];

  server = [EMGObjCHelper startServerWithCallback:^NSData *{
    return getAddresses();
  }];

  if (!isDebuggerAttached()) {
    printf("The debugger is not attached\n");
    abort();
  }
  usleep(500000);
  _dyld_register_func_for_add_image(image_added);
}

#endif
