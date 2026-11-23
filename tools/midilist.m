#import <Foundation/Foundation.h>
#import <CoreMIDI/CoreMIDI.h>
int main(void){@autoreleasepool{
  printf("sources=%lu destinations=%lu\n",(unsigned long)MIDIGetNumberOfSources(),(unsigned long)MIDIGetNumberOfDestinations());
  for(ItemCount i=0;i<MIDIGetNumberOfSources();i++){MIDIEndpointRef ep=MIDIGetSource(i);CFStringRef n=NULL;MIDIObjectGetStringProperty(ep,kMIDIPropertyName,&n);char b[256]={0};if(n)CFStringGetCString(n,b,sizeof b,kCFStringEncodingUTF8);printf("SRC[%lu] '%s'\n",(unsigned long)i,b);}
  for(ItemCount i=0;i<MIDIGetNumberOfDestinations();i++){MIDIEndpointRef ep=MIDIGetDestination(i);CFStringRef n=NULL;MIDIObjectGetStringProperty(ep,kMIDIPropertyName,&n);char b[256]={0};if(n)CFStringGetCString(n,b,sizeof b,kCFStringEncodingUTF8);printf("DST[%lu] '%s'\n",(unsigned long)i,b);}
}return 0;}
