//
//  Constructor.m
//  emergeFaultOrdering
//
//  Created by Noah Martin on 8/1/21.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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

void parseLinkMapFile(NSString *filePath, intptr_t slide, vm_address_t sectionStart, unsigned long sectionSize, void (*callback)(UInt64));

bool parseFunctionStarts(const struct mach_header_64 *header, intptr_t slide, vm_address_t sectionStart, unsigned long sectionSize, void (*callback)(UInt64));

#define DYLD_INTERPOSE(_replacment,_replacee) \
   __attribute__((used)) static struct{ const void* replacment; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacment, (const void*)(unsigned long)&_replacee };

NSMutableArray<NSDictionary *> *loadedImages;
std::vector<uint64_t> *accessedAddresses;

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

void printAddresses() {
  NSMutableArray *arraySamples = [NSMutableArray new];
  for(uint64_t addr : *accessedAddresses) {
    [arraySamples addObject:@(addr)];
  }
  NSDictionary *result = @{
    @"loadedImages": loadedImages,
    @"samples": @[@{@"backtrace": arraySamples}],
  };
  
  NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
  NSURL *documentsURL = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
  NSURL *emergeDirectoryURL = [documentsURL URLByAppendingPathComponent:@"emerge-output"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:emergeDirectoryURL.path isDirectory:NULL]) {
      [[NSFileManager defaultManager] createDirectoryAtURL:emergeDirectoryURL withIntermediateDirectories:YES attributes:nil error:nil];
  }
  NSString *fileName = @"fault-order.json";
  NSURL *outputURL = [emergeDirectoryURL URLByAppendingPathComponent:fileName];
  NSLog(@"Emerge fault order file url: %@", outputURL);
  [data writeToURL:outputURL atomically:YES];
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

void debuggerCallback(mach_port_t thread, arm_thread_state64_t state, std::function<void(bool removeBreak)> sendReply);
void badAccessCallback(mach_port_t thread, arm_thread_state64_t state);

class V2Handler {

public:
  SimpleDebugger *handler;
  std::vector<uint64_t> *accessedAddresses;

  // Static method to provide access to the single instance
  static V2Handler& getInstance() {
      // Lazy instantiation (created the first time it's accessed)
      static V2Handler instance;
      return instance;
  }

  V2Handler() {
    handler = new SimpleDebugger();
    handler->setExceptionCallback(debuggerCallback);
    handler->setBadAccessCallback(badAccessCallback);
    handler->startDebugging();
  }
};

void handleFunctionAddress(UInt64 addr) {
  V2Handler::getInstance().handler->setBreakpoint(addr);
}

void protectSection(const struct mach_header_64 *header, const char* segment, const char* section, vm_prot_t newProtection) {
  unsigned long section_size = 0;
  uint8_t *section_start = getsectiondata(header, segment, section, &section_size);

  // reduce the size to account for us making the sections two pages smaller
  // to guarantee our sections are contained within full pages, we move the start of the section
  // forward by a page, and move the end backwards by a page
  intptr_t new_size = section_size - (vm_page_size * 2);
  if (new_size < 0) {
      os_log(OS_LOG_DEFAULT, "Skipping protection of %s%s because it is not big enough to guarantee that it is contained within it's own unqiue pages", segment, section);
      return;
  }

  kern_return_t result = vm_protect(mach_task_self(), (vm_address_t) section_start + vm_page_size, new_size, 0, newProtection);
  if (result != 0) {
    os_log(OS_LOG_DEFAULT, "error vm protect");
  }
}

bool usingFullPageProtection = false;

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

  NSString *linkmapPath = [NSBundle.mainBundle pathForResource:@"Linkmap" ofType:@"txt"];
  if (linkmapPath) {
    parseLinkMapFile(linkmapPath, slide, section, section_size, &handleFunctionAddress);
  } else {
    bool hasFunctionStarts = parseFunctionStarts((mach_header_64 *) mh, slide, section, section_size, &handleFunctionAddress);
    if (!hasFunctionStarts) {
      const char *textSegment = "__TEXT";
      const char *textSection = "__text";
      usingFullPageProtection = true;
      protectSection((const struct mach_header_64 *)mh, textSegment, textSection, VM_PROT_READ);
    }
  }
}

void debuggerCallback(mach_port_t thread, arm_thread_state64_t state, std::function<void(bool removeBreak)> sendReply) {
    V2Handler::getInstance().accessedAddresses->push_back(state.__pc);
    sendReply(true);
}

vm_address_t pageAlign(vm_address_t address) {
  return address - address % 16384;
}

void badAccessCallback(mach_port_t thread, arm_thread_state64_t state) {
  if (!usingFullPageProtection) {
    return;
  }

  _STRUCT_MCONTEXT64 machineContext;
  mach_msg_type_number_t stateCountBuff = ARM_THREAD_STATE64_COUNT;
  stateCountBuff = ARM_EXCEPTION_STATE64_COUNT;
  kern_return_t kr = thread_get_state(thread, ARM_EXCEPTION_STATE64, (thread_state_t)&machineContext.__es, &stateCountBuff);
  if(kr != KERN_SUCCESS) {
    os_log(OS_LOG_DEFAULT, "Get exception state error");
  }
  uint64_t address = machineContext.__es.__far;
  uint64_t pageAddress = pageAlign(address);
  kr = vm_protect(mach_task_self(), pageAddress, (vm_size_t) 2, 0, VM_PROT_READ | VM_PROT_EXECUTE);
  if (kr != KERN_SUCCESS) {
    os_log(OS_LOG_DEFAULT, "vm protect error: %d", kr);
  }
  V2Handler::getInstance().accessedAddresses->push_back(address);
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

void parseLinkMapFile(NSString *filePath, intptr_t slide, vm_address_t sectionStart, unsigned long sectionSize, void (*callback)(UInt64)) {
  FILE *file = fopen([filePath UTF8String], "r");
  char buffer[256];
  BOOL inTextSection = NO;

  while (fgets(buffer, sizeof(buffer), file) != NULL) {
    if (buffer[255]) {
      bzero(buffer, sizeof(char)*256);
      continue;
    }
    size_t lineLength = strnlen(buffer, sizeof(buffer));
    if (lineLength > 0 && buffer[lineLength - 1] == '\n') {
        buffer[lineLength - 1] = '\0';
    }

    if (!inTextSection) {
        if (strstr(buffer, "# Symbols:")) {
            inTextSection = true;
        }
        continue;
    }

    if (strncmp(buffer, "0x", 2) == 0) {
      char *address = strtok(buffer, "\t");
      strtok(NULL, "\t");
      const char *symbol = strtok(NULL, "\t");
      if (symbol) {
        const char *substringStart = strstr(symbol, "] ");
        symbol = substringStart + 2;
        if (symbol[0] != 'l' && !strstr(symbol, "_OUTLINED_")) {
          UInt64 length = strtoull(address + 2, NULL, 16);
          UInt64 addr = slide + length;

          if (addr >= sectionStart && addr < sectionStart + sectionSize) {
            callback(addr);
          } else {
            break;
          }
        }
      }
    }
  }
  fclose(file);
}

__attribute__((constructor)) void setup(void);
__attribute__((constructor)) void setup() {
  loadedImages = [NSMutableArray new];
  accessedAddresses = new std::vector<uint64_t>();

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

  [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      printAddresses();
      NSLog(@"Fault Order File written, exiting app");
      _exit(0);
    });
  }];

  if (!isDebuggerAttached()) {
    printf("The debugger is not attached\n");
    abort();
  }
  V2Handler::getInstance().accessedAddresses = accessedAddresses;
  usleep(500000);
  _dyld_register_func_for_add_image(image_added);
}
