"""Minimal Wayland virtual pointer (zwlr_virtual_pointer_v1) for live latency tests. Standard library only.
Coordinates are logical layout pixels; send() returns the wall-clock time (ms) the event was flushed."""
import os,socket,struct,time
def _s(text):
 b=text.encode()+b'\0';return struct.pack('<I',len(b))+b+b'\0'*(-len(b)%4)
class Pointer:
 def __init__(self,width,height):
  self.w,self.h=int(width),int(height)
  self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
  self.sock.connect(os.path.join(os.environ['XDG_RUNTIME_DIR'],os.environ.get('WAYLAND_DISPLAY','wayland-0')))
  self.next=2;registry=self._new();self._req(1,1,struct.pack('<I',registry));self._roundtrip()
  globals_={}
  for obj,op,body in self.events:
   if obj==registry and op==0:
    name,=struct.unpack_from('<I',body);n,=struct.unpack_from('<I',body,4);iface=body[8:8+n-1].decode()
    globals_[iface]=name
  if 'zwlr_virtual_pointer_manager_v1' not in globals_:raise RuntimeError('compositor lacks zwlr_virtual_pointer_manager_v1')
  manager=self._new();self._req(registry,0,struct.pack('<I',globals_['zwlr_virtual_pointer_manager_v1'])+_s('zwlr_virtual_pointer_manager_v1')+struct.pack('<II',1,manager))
  self.ptr=self._new();self._req(manager,0,struct.pack('<II',0,self.ptr));self._roundtrip()
 def _new(self):
  self.next+=1;return self.next-1
 def _req(self,obj,op,body=b''):
  self.sock.sendall(struct.pack('<II',obj,(8+len(body))<<16|op)+body)
 def _roundtrip(self):
  cb=self._new();self._req(1,0,struct.pack('<I',cb));self.events=[];buf=b''
  while True:
   buf+=self.sock.recv(65536)
   while len(buf)>=8:
    obj,size_op=struct.unpack_from('<II',buf);size=size_op>>16
    if len(buf)<size:break
    self.events.append((obj,size_op&0xffff,buf[8:size]));buf=buf[size:]
    if obj==1 and size_op&0xffff==0:raise RuntimeError('wayland error: '+repr(self.events[-1][2]))
    if obj==cb:return
 def _t(self):return int(time.monotonic()*1000)&0xffffffff
 def move(self,x,y):
  self._req(self.ptr,1,struct.pack('<IIIII',self._t(),max(0,int(x)),max(0,int(y)),self.w,self.h));self._req(self.ptr,4,struct.pack('<I',self._t()));return time.time()*1000
 def button(self,down,button=0x110):
  self._req(self.ptr,2,struct.pack('<III',self._t(),button,1 if down else 0));self._req(self.ptr,4,struct.pack('<I',self._t()));return time.time()*1000
 def drag(self,points,interval=1/60,hold=0.15):
  """Press at points[0], move through the rest at `interval`, release. Returns send times of each motion."""
  self.move(*points[0]);time.sleep(.05);self.button(True);time.sleep(hold);sent=[]
  for p in points[1:]:sent.append(self.move(*p));time.sleep(interval)
  time.sleep(hold);self.button(False);return sent
 def close(self):
  self._req(self.ptr,8);self._roundtrip();self.sock.close()
