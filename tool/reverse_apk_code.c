// APK 3.0.9 protocol audit fallback for a rooted, user-owned Android device.
// Read only DEX headers and validated code containers from com.copymanga.app.
// Never exports a general memory/heap dump or reads app preferences/databases.
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/syscall.h>

static ssize_t read_code(int pid, void *buffer, size_t size, unsigned long at) {
  struct iovec local={buffer,size}, remote={(void*)at,size};
  return syscall(__NR_process_vm_readv,pid,&local,1,&remote,1,0);
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  int pid = atoi(argv[1]);
  char path[256], cmdline[128] = {0};
  snprintf(path, sizeof path, "/proc/%d/cmdline", pid);
  int command = open(path, O_RDONLY);
  if (command < 0) return 3;
  read(command, cmdline, sizeof cmdline - 1); close(command);
  if (strcmp(cmdline, "com.copymanga.app")) return 4;
  snprintf(path, sizeof path, "/proc/%d/maps", pid);
  FILE *maps = fopen(path, "r");
  if (!maps) {perror("read-only maps"); return 5;}
  mkdir(argv[2], 0700);
  char line[2048]; int count=0, probes=0;
  while (fgets(line, sizeof line, maps)) {
    unsigned long start, end, offset, inode;
    char perms[8], dev[16]; int used=0;
    if (sscanf(line, "%lx-%lx %7s %lx %15s %lu %n", &start,&end,perms,&offset,dev,&inode,&used)<6) continue;
    // Unnamed private mappings only. Excludes heaps, stacks, system and app
    // data files, GPU mappings, and all named Java/Flutter allocation arenas.
    if (perms[0]!='r' || perms[3]!='p' || inode ||
        strspn(line+used," \t\r\n") != strlen(line+used) ||
        end-start > 64*1024*1024) continue;
    for (unsigned long at=start; at+112<=end; at+=4096) {
      unsigned char header[112]; probes++;
      if (read_code(pid, header, sizeof header, at)!=sizeof header) continue;
      if (memcmp(header,"dex\n0",5) || header[7]!=0) continue;
      uint32_t size, hdr, endian;
      memcpy(&size,header+32,4); memcpy(&hdr,header+36,4); memcpy(&endian,header+40,4);
      if (hdr!=112 || endian!=0x12345678 || size<112 || size>64*1024*1024 || at+size>end) continue;
      unsigned char *data=malloc(size);
      if (!data || read_code(pid,data,size,at)!=size) {free(data); continue;}
      snprintf(path,sizeof path,"%s/code-%lx.dex",argv[2],at);
      int out=open(path,O_WRONLY|O_CREAT|O_EXCL,0600);
      if (out>=0) {write(out,data,size);close(out);count++; printf("DEX %lx %u bytes\n",at,size);}
      free(data); at+=(size-1)/4096*4096;
    }
  }
  printf("headers checked=%d DEX containers=%d\n",probes,count);
  fclose(maps); return 0;
}
