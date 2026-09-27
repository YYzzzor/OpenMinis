(function(){
  'use strict';
  const {defaults,buildSVG}=window.MinisIcon;
  let params={...defaults}, flat=false, lastSVG='', scheduled=false;
  const fields=['centerScale','softness','surroundSpread','satelliteScale','texture','grain','shading','warmth'];
  const storageKey='minisx-icon-study-v1';
  try{const saved=JSON.parse(localStorage.getItem(storageKey));if(saved)for(const key of fields){const input=document.getElementById(key);if(Number.isFinite(saved[key]))params[key]=Math.max(+input.min,Math.min(+input.max,saved[key]));}}catch{}
  function sync(){for(const key of fields){document.getElementById(key).value=params[key];document.getElementById(`${key}-value`).value=`${Math.round(params[key]*100)}%`;}}
  function render(){
    scheduled=false;
    lastSVG=buildSVG(flat?{...params,shading:0}:params,{textured:!flat});
    document.getElementById('rendered').innerHTML=lastSVG;
    const uri='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(lastSVG);
    for(const size of [96,60,32])document.getElementById(`small-${size}`).src=uri;
    sync();
  }
  function queue(){if(!scheduled){scheduled=true;requestAnimationFrame(render);}}
  function status(s){document.getElementById('status').textContent=s;}
  for(const key of fields)document.getElementById(key).addEventListener('input',e=>{params[key]=+e.target.value;sync();queue();try{localStorage.setItem(storageKey,JSON.stringify(params));}catch{status('当前参数仅在本次打开期间保留。');}});
  for(const mode of ['full','flat'])document.getElementById(mode).addEventListener('click',()=>{
    flat=mode==='flat';for(const m of ['full','flat']){const el=document.getElementById(m);el.classList.toggle('active',m===mode);el.setAttribute('aria-pressed',String(m===mode));}
    document.getElementById('mode-label').textContent=flat?'纯色 · 轮廓与布局':'形状 + 渐变 + 纹理';queue();
  });
  document.getElementById('mask').addEventListener('click',e=>{const on=document.getElementById('pair').classList.toggle('mask');e.currentTarget.classList.toggle('active',on);e.currentTarget.setAttribute('aria-pressed',String(on));});
  document.getElementById('reset').addEventListener('click',()=>{params={...defaults};try{localStorage.removeItem(storageKey);}catch{}sync();queue();status('已恢复初始复现参数。');});
  function download(content,type,name){const url=URL.createObjectURL(new Blob([content],{type}));const a=document.createElement('a');a.href=url;a.download=name;document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1500);status(`已导出 ${name}`);}
  document.getElementById('export-svg').addEventListener('click',()=>download(buildSVG(params),'image/svg+xml','minisx-no-word.svg'));
  document.getElementById('export-flat').addEventListener('click',()=>download(buildSVG(params,{textured:false}),'image/svg+xml','minisx-no-word-vector.svg'));
  document.getElementById('export-json').addEventListener('click',()=>download(JSON.stringify({version:1,params},null,2),'application/json','minisx-icon-parameters.json'));
  document.getElementById('export-png').addEventListener('click',async()=>{
    try{const svg=buildSVG(params);const image=new Image();image.src='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(svg);await image.decode();const canvas=document.createElement('canvas');canvas.width=canvas.height=1024;canvas.getContext('2d').drawImage(image,0,0);const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/png'));if(!blob)throw Error('输出为空');download(blob,'image/png','minisx-no-word.png');}catch(e){status('PNG 导出失败：'+e.message);}
  });
  // 便于自动验证和离线导出，不依赖界面显示状态。
  window.iconStudy={getParams:()=>({...params}),svg:(options={})=>buildSVG(params,options),reset:()=>{params={...defaults};render();}};
  render();
})();
