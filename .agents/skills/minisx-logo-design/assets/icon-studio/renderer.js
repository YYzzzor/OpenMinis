/* MinisX 无字图标：轮廓使用 SVG，表面纹理由 Canvas 确定性生成。
 * reference-light.png 仅供界面对照；本文件不读取、裁切或嵌入原图。
 */
(function () {
  'use strict';
  const NS = 'http://www.w3.org/2000/svg';
  const defaults = Object.freeze({
    centerScale: 1, surroundSpread: 1, satelliteScale: 1, softness: 1,
    texture: 0.65, grain: 0.28, shading: 1, warmth: 0, seed: 270926
  });

  // 控制点沿原图轮廓手工重建；每个形状保留稳定 id，便于局部调整。
  const shapes = [
    { id: 'top-coral', label: '左上珊瑚色', center: [389,195],
      d: 'M 319 172 C 330 148 351 133 378 130 C 408 126 429 145 443 169 C 455 189 468 216 460 236 C 451 258 429 262 405 258 C 378 253 352 243 334 222 C 319 205 311 187 319 172 Z',
      light:'#f39b82', mid:'#d56957', dark:'#983a31', focus:[330,140], radius:172 },
    { id:'top-sage', label:'上方橄榄色', center:[627,158],
      d:'M 624 123 C 645 121 659 137 661 155 C 665 174 653 189 636 193 C 618 197 601 187 595 171 C 588 153 597 135 609 128 C 614 125 619 124 624 123 Z',
      light:'#bbb299',mid:'#958b72',dark:'#716750',focus:[599,129],radius:79 },
    { id:'upper-left-cream',label:'左上米色',center:[271,324],
      d:'M 275 281 C 294 282 303 299 308 316 C 313 332 311 351 299 361 C 286 372 269 368 253 357 C 238 347 228 333 231 316 C 234 299 254 281 275 281 Z',
      light:'#f2d9bf',mid:'#dfb99a',dark:'#b7876a',focus:[243,291],radius:103 },
    { id:'upper-right-ochre',label:'右上赭黄色',center:[759,291],
      d:'M 796 236 C 816 241 820 258 815 278 C 810 302 792 328 771 342 C 752 354 731 353 714 341 C 698 330 699 310 707 291 C 715 270 735 249 755 239 C 769 232 785 231 796 236 Z',
      light:'#f4c295',mid:'#d58c53',dark:'#a25b37',focus:[720,237],radius:122 },
    { id:'left-clay',label:'左侧陶土色',center:[174,461],
      d:'M 192 414 C 209 412 217 426 220 444 C 224 466 220 486 207 498 C 194 510 174 510 155 502 C 136 494 121 485 122 468 C 123 452 138 436 153 427 C 167 419 181 414 192 414 Z',
      light:'#d9b6a0',mid:'#b38872',dark:'#865745',focus:[139,421],radius:111 },
    { id:'right-coral',label:'右侧珊瑚色',center:[864,427],
      d:'M 859 388 C 882 386 898 402 901 420 C 905 441 892 459 875 463 C 854 470 833 455 828 438 C 821 417 833 392 852 389 C 854 388 857 388 859 388 Z',
      light:'#f58a69',mid:'#d55840',dark:'#9d3229',focus:[835,398],radius:86 },
    { id:'right-clay',label:'右下陶土色',center:[844,582],
      d:'M 823 531 C 845 528 868 541 885 558 C 901 574 907 591 896 607 C 883 623 866 633 848 635 C 830 636 815 627 805 610 C 794 593 788 575 793 558 C 797 543 808 533 823 531 Z',
      light:'#d1aa94',mid:'#aa7b66',dark:'#805040',focus:[797,538],radius:109 },
    { id:'lower-left-coral',label:'左下珊瑚色',center:[220,646],
      d:'M 239 598 C 259 598 270 607 271 624 C 272 644 256 665 238 678 C 221 690 199 695 183 687 C 166 680 162 665 171 645 C 181 623 216 597 239 598 Z',
      light:'#f59170',mid:'#dc6448',dark:'#b94630',focus:[185,612],radius:99 },
    { id:'lower-left-ochre',label:'左下赭黄色',center:[298,775],
      d:'M 335 713 C 355 717 366 732 364 751 C 362 774 344 797 325 815 C 307 831 283 841 262 838 C 240 835 228 823 231 804 C 234 782 249 758 267 739 C 286 720 313 707 335 713 Z',
      light:'#edc096',mid:'#d1935d',dark:'#a56942',focus:[246,730],radius:132 },
    { id:'lower-right-sage',label:'右下橄榄色',center:[728,767],
      d:'M 754 695 C 773 696 785 716 792 741 C 798 763 802 790 793 813 C 787 833 775 841 754 837 C 728 834 696 824 674 810 C 655 799 651 786 659 770 C 670 748 698 724 721 707 C 734 698 744 694 754 695 Z',
      light:'#beb599',mid:'#918970',dark:'#6e634c',focus:[672,710],radius:145 },
    { id:'bottom-clay',label:'下方陶土色',center:[512,854],
      d:'M 512 815 C 534 815 550 831 552 849 C 554 869 543 886 524 892 C 503 898 483 887 476 870 C 468 851 475 832 490 822 C 497 818 504 815 512 815 Z',
      light:'#c89980',mid:'#ad7863',dark:'#865241',focus:[482,825],radius:91 },
    { id:'center',label:'中央主体',center:[513,522],
      d:'M 511 330 C 548 328 573 344 590 370 C 605 392 611 418 635 440 C 656 459 682 470 698 492 C 714 514 717 537 704 559 C 690 584 662 596 638 611 C 615 624 600 649 584 673 C 564 702 538 715 509 714 C 477 714 455 698 439 673 C 425 651 418 628 393 613 C 367 598 339 589 324 566 C 310 545 311 522 321 503 C 334 479 360 465 383 448 C 405 431 415 407 431 383 C 451 353 476 333 511 330 Z',
      light:'#ffba91',mid:'#e18462',dark:'#973c32',focus:[388,377],radius:386 }
  ];

  function random(seed) {
    let a = seed >>> 0;
    return () => { a += 0x6D2B79F5; let t = Math.imul(a ^ a >>> 15, 1 | a); t ^= t + Math.imul(t ^ t >>> 7, 61 | t); return ((t ^ t >>> 14) >>> 0) / 4294967296; };
  }
  const cache = new Map();
  function textureAssets(seed) {
    if (cache.has(seed)) return cache.get(seed);
    const rng = random(seed), canvas = document.createElement('canvas');
    canvas.width = canvas.height = 1024;
    const ctx = canvas.getContext('2d');
    ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    // 短曲线围绕扰动的椭圆卷曲，形成细密而不重复的浅色纹路。
    for (let i=0; i<45000; i++) {
      const x=rng()*1024,y=rng()*1024,r=1.8+rng()*2.5,ratio=.55+rng()*.55;
      const angle=rng()*Math.PI*2,turn=(1.15+rng()*.70)*Math.PI,rot=rng()*6.28;
      ctx.strokeStyle=`rgba(255,233,204,${.085+rng()*.12})`;
      ctx.lineWidth=.40+rng()*.25;ctx.beginPath();
      for(let k=0;k<=18;k++) {
        const t=angle+k/18*turn,rr=r*(1+.18*Math.sin(t*3+i));
        const px=Math.cos(t)*rr,py=Math.sin(t)*rr*ratio;
        const xx=x+px*Math.cos(rot)-py*Math.sin(rot),yy=y+px*Math.sin(rot)+py*Math.cos(rot);
        k===0?ctx.moveTo(xx,yy):ctx.lineTo(xx,yy);
      } ctx.stroke();
    }
    const threads=canvas.toDataURL('image/png');
    ctx.clearRect(0,0,1024,1024);
    const pixels=ctx.createImageData(1024,1024);
    for(let i=0;i<pixels.data.length;i+=4) {
      const shade=rng()>.5?255:45;
      pixels.data[i]=shade;pixels.data[i+1]=shade;pixels.data[i+2]=shade;
      pixels.data[i+3]=Math.round(rng()*12);
    }
    ctx.putImageData(pixels,0,0);
    const assets={threads,grain:canvas.toDataURL('image/png')};
    if(cache.size>5)cache.clear();cache.set(seed,assets);return assets;
  }
  const num = n => Number(n.toFixed(3));
  function buildSVG(options={}, {textured=true, only=null, background=true}={}) {
    const p={...defaults,...options}, assets=textured?textureAssets(p.seed):null;
    const amount=p.shading;
    let defs='', layers='';
    for(const shape of shapes) {
      if(only && only!==shape.id)continue;
      const id=shape.id, [cx,cy]=shape.center;
      const central=id==='center';
      const dx=central?0:(cx-512)*(p.surroundSpread-1),dy=central?0:(cy-512)*(p.surroundSpread-1);
      const scale=central?p.centerScale:p.satelliteScale;
      // 中央轮廓的纵向伸缩只用于本轮微调；任意局部曲率可继续修改路径控制点。
      const sy=central?scale*p.softness:scale;
      const transform=`translate(${num(cx+dx)} ${num(cy+dy)}) scale(${num(scale)} ${num(sy)}) translate(${-cx} ${-cy})`;
      if(central) {
        // 原图采样用于校准暖色明暗；颜色值是参数，原图像素不会进入输出。
        defs+='<linearGradient id="g-center" gradientUnits="userSpaceOnUse" x1="320" y1="330" x2="600" y2="730"><stop offset="0" stop-color="#ffd0a6"/><stop offset=".23" stop-color="#fbaf89"/><stop offset=".335" stop-color="#ed9573"/><stop offset=".53" stop-color="#db7457"/><stop offset=".72" stop-color="#a8483b"/><stop offset=".85" stop-color="#a1463a"/><stop offset="1" stop-color="#953b32"/></linearGradient>';
      } else {
        defs+=`<radialGradient id="g-${id}" gradientUnits="userSpaceOnUse" cx="${shape.focus[0]}" cy="${shape.focus[1]}" r="${shape.radius}"><stop offset="0" stop-color="${shape.light}"/><stop offset=".43" stop-color="${shape.mid}"/><stop offset="1" stop-color="${shape.dark}"/></radialGradient>`;
      }
      defs+=`<clipPath id="c-${id}"><path d="${shape.d}"/></clipPath>`;
      layers+=`<g id="${id}" transform="${transform}" data-label="${shape.label}"><path d="${shape.d}" fill="${shape.mid}"/><path d="${shape.d}" fill="url(#g-${id})" opacity="${amount}"/>`;
      if(textured)layers+=`<g clip-path="url(#c-${id})"><use href="#thread-image" opacity="${p.texture}"/><use href="#grain-image" opacity="${p.grain}"/></g>`;
      if(p.warmth)layers+=`<path d="${shape.d}" fill="${p.warmth>0?'#f5a461':'#839cac'}" opacity="${Math.abs(p.warmth)*.22}"/>`;
      layers+='</g>';
    }
    if(textured)defs+=`<image id="thread-image" width="1024" height="1024" href="${assets.threads}"/><image id="grain-image" width="1024" height="1024" href="${assets.grain}"/>`;
    defs+='<radialGradient id="paper" cx="48%" cy="46%" r="76%"><stop stop-color="#f1e7d9"/><stop offset="1" stop-color="#f4eadc"/></radialGradient>';
    const bg=background?`<rect width="1024" height="1024" fill="url(#paper)"/>${textured?'<use href="#grain-image" opacity=".12"/>':''}`:'';
    return `<svg xmlns="${NS}" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-label="MinisX 无字图标程序复现"><title>MinisX 无字图标 · 参数化复现</title><desc>SVG 绘制一个圆润的橙红主体和十一个外围形状；细纹与颗粒由 Canvas 生成。未嵌入原始图标。</desc><defs>${defs}</defs>${bg}${layers}</svg>`;
  }
  window.MinisIcon = {defaults,shapes,buildSVG,textureAssets};
})();
