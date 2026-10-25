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
