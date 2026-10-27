.pragma library

function clone(value) { return JSON.parse(JSON.stringify(value)) }
function point(op,t) {
    var ax=Number(op.x||0),ay=Number(op.y||0),bx=Number(op.x2===undefined?ax+(op.w||0):op.x2),by=Number(op.y2===undefined?ay+(op.h||0):op.y2)
    if(op.cx!==undefined && op.cy!==undefined) return {x:(1-t)*(1-t)*ax+2*(1-t)*t*op.cx+t*t*bx,y:(1-t)*(1-t)*ay+2*(1-t)*t*op.cy+t*t*by}
    return {x:ax+(bx-ax)*t,y:ay+(by-ay)*t}
}
function bounds(op) {
    var x=Number(op.x||0),y=Number(op.y||0),w=Number(op.w||0),h=Number(op.h||0),size=Number(op.size||28)
    if(op.type==='line'||op.type==='arrow') {
        var xs=[],ys=[];for(var i=0;i<=32;i++){var p=point(op,i/32);xs.push(p.x);ys.push(p.y)}
        return {x:Math.min.apply(null,xs),y:Math.min.apply(null,ys),w:Math.max(8,Math.max.apply(null,xs)-Math.min.apply(null,xs)),h:Math.max(8,Math.max.apply(null,ys)-Math.min.apply(null,ys))}
    }
    if(op.type==='freehand' && op.points && op.points.length){var px=op.points.map(function(p){return p.x}),py=op.points.map(function(p){return p.y});return{x:Math.min.apply(null,px),y:Math.min.apply(null,py),w:Math.max(1,Math.max.apply(null,px)-Math.min.apply(null,px)),h:Math.max(1,Math.max.apply(null,py)-Math.min.apply(null,py))}}
    if(op.type==='step'){var r=size*.8;return{x:x-r,y:y-r,w:r*2,h:r*2}}
    if(op.type==='text'&&w>0&&h>0)return {x:x,y:y,w:w,h:h}
    if(op.type==='text'){var lines=String(op.text||'').split('\n');w=Math.max(24,w,Math.max.apply(null,lines.map(function(l){return l.length}))*size*.66);h=Math.max(size*1.4,h,lines.length*size*1.4)}
    return {x:x,y:y,w:Math.max(2,w),h:Math.max(2,h)}
}
function distance(a,b) { var x=a.x-b.x,y=a.y-b.y;return Math.sqrt(x*x+y*y) }
function segmentDistance(p,a,b){var dx=b.x-a.x,dy=b.y-a.y,d=dx*dx+dy*dy,t=d?Math.max(0,Math.min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/d)):0;return distance(p,{x:a.x+t*dx,y:a.y+t*dy})}
function hit(op,x,y,tolerance) {
    if(['background','crop','resize','rotate','flip'].indexOf(op.type)>=0)return false
    var p={x:x,y:y}
    if(op.type==='line'||op.type==='arrow'){for(var i=1;i<=64;i++)if(segmentDistance(p,point(op,(i-1)/64),point(op,i/64))<Math.max(tolerance,Number(op.width||4)*2))return true;return false}
    if(op.type==='freehand'&&op.points){for(var j=1;j<op.points.length;j++)if(segmentDistance(p,op.points[j-1],op.points[j])<tolerance*1.5)return true;return false}
    var b=bounds(op);return x>=b.x-tolerance&&x<=b.x+b.w+tolerance&&y>=b.y-tolerance&&y<=b.y+b.h+tolerance
}
function hitIndex(ops,x,y,tolerance){for(var i=ops.length-1;i>=0;i--)if(hit(ops[i],x,y,tolerance))return i;return -1}
function moved(op,dx,dy){var n=clone(op);['x','x2','cx'].forEach(function(k){if(n[k]!==undefined)n[k]+=dx});['y','y2','cy'].forEach(function(k){if(n[k]!==undefined)n[k]+=dy});if(n.points)n.points=n.points.map(function(p){return{x:p.x+dx,y:p.y+dy}});return n}
function handles(op){
    if(op.type==='line'||op.type==='arrow'){var a=[{key:'start',x:op.x,y:op.y},{key:'end',x:op.x2,y:op.y2}];if(op.type==='arrow'){var p=point(op,.5);a.push({key:'curve',x:p.x,y:p.y})}return a}
    var b=bounds(op);return [{key:'nw',x:b.x,y:b.y},{key:'n',x:b.x+b.w/2,y:b.y},{key:'ne',x:b.x+b.w,y:b.y},{key:'e',x:b.x+b.w,y:b.y+b.h/2},{key:'se',x:b.x+b.w,y:b.y+b.h},{key:'s',x:b.x+b.w/2,y:b.y+b.h},{key:'sw',x:b.x,y:b.y+b.h},{key:'w',x:b.x,y:b.y+b.h/2}]
}
function resized(op,key,x,y){
    var n=clone(op)
    if(key==='start'){n.x=x;n.y=y;return n}if(key==='end'){n.x2=x;n.y2=y;return n}
    if(key==='curve'){n.cx=2*x-(n.x+n.x2)/2;n.cy=2*y-(n.y+n.y2)/2;return n}
    var b=bounds(op),left=b.x,top=b.y,right=b.x+b.w,bottom=b.y+b.h
    if(key.indexOf('w')>=0)left=Math.min(x,right-2);if(key.indexOf('e')>=0)right=Math.max(x,left+2)
    if(key.indexOf('n')>=0)top=Math.min(y,bottom-2);if(key.indexOf('s')>=0)bottom=Math.max(y,top+2)
    var sx=(right-left)/b.w,sy=(bottom-top)/b.h
    if(op.type==='step'){n.x=(left+right)/2;n.y=(top+bottom)/2;n.size=Math.max(10,(right-left)/1.6)}
    else if(op.type==='text'){n.x=left;n.y=top;n.size=Math.max(10,Math.min(144,(op.size||28)*Math.max(sx,sy)));n.w=0;n.h=0}
    else if(op.type==='freehand'){n.points=op.points.map(function(p){return{x:left+(p.x-b.x)*sx,y:top+(p.y-b.y)*sy}});n.x=left;n.y=top;n.w=right-left;n.h=bottom-top}
    else{n.x=left;n.y=top;n.w=right-left;n.h=bottom-top}
    return n
}

// Live preview helpers. These mirror the backend render (main.rs `render`, background.rs `compose`) so the GPU scene
// lines up with the exact backend pixels that replace it.
function num(o,k,d){var v=o?o[k]:undefined;return typeof v==='number'&&isFinite(v)?v:d}
function clamp(v,a,b){return Math.max(a,Math.min(b,v))}
function u32(v){return v>0?Math.floor(v):0}
function trunc(v){return v<0?Math.ceil(v):Math.floor(v)}
// Backend colors are #rgb, #rrggbb or #rrggbbaa; QML reads 8 digits as #aarrggbb.
function qmlColor(c){c=typeof c==='string'&&/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(c)?c:'#f05a70';return c.length===9?'#'+c.slice(7)+c.slice(1,7):c}
function documentSize(w,h,ops){ops.forEach(function(o){if(o.type==='image'){w=Math.max(w,u32(Math.max(1,num(o,'x',0)+Math.max(1,num(o,'w',100)))));h=Math.max(h,u32(Math.max(1,num(o,'y',0)+Math.max(1,num(o,'h',100)))))}});return{w:w,h:h}}
// Overlay annotations (main.rs `is_overlay`) draw above the background and grow the canvas when they leave it.
var overlayTypes=['line','arrow','rectangle','filled','ellipse','freehand','text','step','highlight']
function isOverlay(o){return !!o&&o.overlay===true&&overlayTypes.indexOf(o.type)>=0}
// Geometric and inked bounds [x0,y0,x1,y1], like main.rs `overlay_bounds`.
function overlayBounds(op){
    var x=num(op,'x',0),y=num(op,'y',0),w=Math.max(1,num(op,'w',100)),h=Math.max(1,num(op,'h',100)),half=clamp(num(op,'width',4),1,100)/2,t=op.type
    function hull(p){return p.reduce(function(b,q){return[Math.min(b[0],q[0]),Math.min(b[1],q[1]),Math.max(b[2],q[0]),Math.max(b[3],q[1])]},[Infinity,Infinity,-Infinity,-Infinity])}
    function grow(b,d){return[b[0]-d,b[1]-d,b[2]+d,b[3]+d]}
    var g
    if(t==='line'||t==='arrow'){var p=[[x,y],[num(op,'x2',x+w),num(op,'y2',y+h)]];if(typeof op.cx==='number'&&typeof op.cy==='number')p.push([op.cx,op.cy]);g=hull(p);return[g,grow(g,t==='arrow'?half*9:half)]}
    if(t==='freehand'){var pts=(op.points||[]).map(function(q){return[num(q,'x',0),num(q,'y',0)]});g=pts.length?hull(pts):[x,y,x,y];return[g,grow(g,half)]}
    if(t==='text'){var size=clamp(num(op,'size',28),6,500),chars=Array.from(typeof op.text==='string'?op.text:'1').length;g=[x,y,x+num(op,'w',Math.max(8,chars*size*.63)),y+num(op,'h',size*1.4)];return[g,[g[0]-8,g[1]-4,g[2]+8,g[3]+4]]}
    if(t==='step'){var r=clamp(num(op,'size',28),6,500)*.7+half;g=[x-r,y-r,x+r,y+r];return[g,g]}
    g=[x,y,x+w,y+h];return[g,t==='highlight'?g:grow(g,half)]
}
// Extra canvas {l,t,r,b} for overlays on a w x h canvas with the source origin at (tx,ty), like main.rs `overlay_growth`.
function growth(ops,tx,ty,w,h){
    var o={l:0,t:0,r:0,b:0}
    function side(cross,need){return cross?Math.max(0,Math.ceil(need+24)):0}
    ops.forEach(function(op){if(!isOverlay(op))return;var b=overlayBounds(op),g=b[0],v=b[1]
        o.l=Math.max(o.l,side(g[0]+tx<0,-(v[0]+tx)));o.t=Math.max(o.t,side(g[1]+ty<0,-(v[1]+ty)))
        o.r=Math.max(o.r,side(g[2]+tx>w,v[2]+tx-w));o.b=Math.max(o.b,side(g[3]+ty>h,v[3]+ty-h))})
    return o
}
function sceneLayout(w,h,bg,balance,overlays){
    var full={x:0,y:0,w:w,h:h,sourceX:0,sourceY:0,sourceW:w,sourceH:h},g
    if(!bg){g=growth(overlays||[],0,0,w,h);return{w:w+g.l+g.r,h:h+g.t+g.b,frame:{x:g.l,y:g.t,w:w,h:h},inset:0,grown:g.l+g.t+g.r+g.b>0,content:{x:g.l,y:g.t,w:w,h:h,sourceX:0,sourceY:0,sourceW:w,sourceH:h}}}
    var pad=u32(clamp(num(bg,'padding',64),0,2000)),inset=u32(clamp(num(bg,'inset',0),0,200)),auto=typeof bg.auto_balance==='boolean'?bg.auto_balance:true
    var b=bg.gradient_version===2&&auto&&balance&&balance.w>0&&balance.x+balance.w<=w&&balance.y+balance.h<=h?balance:full
    var fw=b.w+inset*2,fh=b.h+inset*2,W=fw+pad*2,H=fh+pad*2,aspect=clamp(num(bg,'aspect_ratio',0),0,10),a=typeof bg.alignment==='string'?bg.alignment:'center'
    if(aspect>.1){if(W/H>aspect)H=Math.ceil(W/aspect);else W=Math.ceil(H*aspect)}
    var x=Math.floor((W-fw)/2),y=Math.floor((H-fh)/2)
    var edge=function(spare){return bg.alignment_version===2?Math.min(pad,spare-pad-Math.ceil(pad/2)):pad},mx=edge(W-fw),my=edge(H-fh)
    if(a.indexOf('left')>=0)x=mx;if(a.indexOf('right')>=0)x=W-fw-mx;if(a.indexOf('top')>=0)y=my;if(a.indexOf('bottom')>=0)y=H-fh-my
    var offset=trunc(clamp(num(bg,'shadow_offset',8),-100,100))
    if(auto&&a==='center'&&H>fh+pad*2)y=clamp(y-trunc(offset/2),pad,H-fh-pad)
    g=growth(overlays||[],x+inset-b.x,y+inset-b.y,W,H);x+=g.l;y+=g.t;W+=g.l+g.r;H+=g.t+g.b
    return{w:W,h:H,frame:{x:x,y:y,w:fw,h:fh},inset:inset,offset:offset,content:{x:x+inset,y:y+inset,w:b.w,h:b.h,sourceX:b.x,sourceY:b.y,sourceW:b.w,sourceH:b.h}}
}
function freehandPoints(op){
    var pts=op.points||[],stride=Math.max(1,Math.floor(pts.length/500)),p=[],i
    for(i=0;i<pts.length;i+=stride)p.push([num(pts[i],'x',0),num(pts[i],'y',0)])
    var last=pts[pts.length-1];if(last&&(p[p.length-1][0]!==num(last,'x',0)||p[p.length-1][1]!==num(last,'y',0)))p.push([num(last,'x',0),num(last,'y',0)])
    if(op.smooth!==false&&p.length>2)for(var k=0;k<2;k++){var s=[p[0]];for(i=1;i<p.length;i++){var a=p[i-1],b=p[i];s.push([a[0]*.75+b[0]*.25,a[1]*.75+b[1]*.25],[a[0]*.25+b[0]*.75,a[1]*.25+b[1]*.75])}s.push(p[p.length-1]);p=s}
    return p
}
// SVG paths in image pixels. ImageMagick puts integer coordinates on pixel centers, hence the half-pixel shift.
function svgPath(op){
    var t=op.type,x=num(op,'x',0)+.5,y=num(op,'y',0)+.5,w=Math.max(1,num(op,'w',100)),h=Math.max(1,num(op,'h',100)),x2=num(op,'x2',x-.5+w)+.5,y2=num(op,'y2',y-.5+h)+.5
    if(t==='rectangle'||t==='filled')return'M'+x+' '+y+'H'+(x+w)+'V'+(y+h)+'H'+x+'Z'
    if(t==='ellipse'){var rx=w/2,ry=h/2,cx=x+rx,cy=y+ry;return'M'+(cx-rx)+' '+cy+'A'+rx+' '+ry+' 0 1 0 '+(cx+rx)+' '+cy+'A'+rx+' '+ry+' 0 1 0 '+(cx-rx)+' '+cy+'Z'}
    if(t==='freehand')return freehandPoints(op).map(function(p,i){return(i?'L':'M')+(p[0]+.5)+' '+(p[1]+.5)}).join('')
    if(t==='arrow'&&typeof op.cx==='number'&&typeof op.cy==='number')return'M'+x+' '+y+'Q'+(op.cx+.5)+' '+(op.cy+.5)+' '+x2+' '+y2
    return'M'+x+' '+y+'L'+x2+' '+y2
}
function arrowHead(op){
    var x=num(op,'x',0),y=num(op,'y',0),x2=num(op,'x2',x+Math.max(1,num(op,'w',100))),y2=num(op,'y2',y+Math.max(1,num(op,'h',100))),curved=typeof op.cx==='number'&&typeof op.cy==='number'
    var angle=curved?Math.atan2(y2-op.cy,x2-op.cx):Math.atan2(y2-y,x2-x),len=clamp(num(op,'width',4),1,100)*4
    return'M'+(x2+.5)+' '+(y2+.5)+'L'+(x2-len*Math.cos(angle-.5)+.5)+' '+(y2-len*Math.sin(angle-.5)+.5)+'L'+(x2-len*Math.cos(angle+.5)+.5)+' '+(y2-len*Math.sin(angle+.5)+.5)+'Z'
}
// Raster operations act on whole pixels clamped to the image, like `raster_op`.
// (ox,oy) places the op's coordinates on the image (overlays sit at the source origin), the box is returned in op coordinates.
function rasterBox(op,w,h,ox,oy){ox=ox||0;oy=oy||0;var x=u32(Math.max(0,num(op,'x',0)+ox)),y=u32(Math.max(0,num(op,'y',0)+oy));return{x:x-ox,y:y-oy,w:Math.min(u32(Math.max(1,num(op,'w',1))),Math.max(0,w-x)),h:Math.min(u32(Math.max(1,num(op,'h',1))),Math.max(0,h-y))}}
function roundedRect(x,y,w,h,r){r=Math.max(0,Math.min(r,w/2,h/2));return'M'+(x+r)+' '+y+'H'+(x+w-r)+'A'+r+' '+r+' 0 0 1 '+(x+w)+' '+(y+r)+'V'+(y+h-r)+'A'+r+' '+r+' 0 0 1 '+(x+w-r)+' '+(y+h)+'H'+(x+r)+'A'+r+' '+r+' 0 0 1 '+x+' '+(y+h-r)+'V'+(y+r)+'A'+r+' '+r+' 0 0 1 '+(x+r)+' '+y+'Z'}
// A transform's output size and affine map {m11,m12,dx,m21,m22,dy}, for drawing it live until its exact base is rendered.
function transformOf(op,w,h){
    var t=op.type,a,c,s,q,W,H
    if(t==='crop'){W=u32(Math.max(1,num(op,'w',100)));H=u32(Math.max(1,num(op,'h',100)));return{w:W,h:H,m:[1,0,-trunc(num(op,'x',0)),0,1,-trunc(num(op,'y',0))],fill:qmlColor(typeof op.background_color==='string'?op.background_color:'#00000000')}}
    if(t==='flip')return op.axis==='horizontal'?{w:w,h:h,m:[-1,0,w,0,1,0]}:{w:w,h:h,m:[1,0,0,0,-1,h]}
    if(t==='resize'){W=u32(Math.max(1,num(op,'w',100)));H=u32(Math.max(1,num(op,'h',100)));return{w:W,h:H,m:[W/w,0,0,0,H/h,0]}}
    if(t==='rotate'){a=num(op,'angle',90);q=Math.abs(a)%90===0;c=Math.cos(a*Math.PI/180);s=Math.sin(a*Math.PI/180);if(q){c=Math.round(c);s=Math.round(s)}
        W=Math.ceil(Math.abs(w*c)+Math.abs(h*s)-1e-9);H=Math.ceil(Math.abs(w*s)+Math.abs(h*c)-1e-9);return{w:W,h:H,m:[c,-s,W/2-c*w/2+s*h/2,s,c,H/2-s*w/2-c*h/2]}}
    return{w:w,h:h,m:[1,0,0,0,1,0]}
}
