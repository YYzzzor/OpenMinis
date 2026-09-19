#!/usr/bin/env python3
"""Check offline architecture navigation with Playwright and Chromium.

Run from any directory. Requires Python Playwright and a Chromium browser.
The script reads only local guide files and writes validation.json.
"""
from pathlib import Path
import json, os, shutil
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[1]
D=json.loads((ROOT/'architecture-data.json').read_text())
checks=[];errors=[];requests=[]
def ck(label,value,detail=None):
 checks.append(dict(check=label,passed=bool(value),detail=detail));assert value,(label,detail)
with sync_playwright() as pw:
 browser_path = (os.environ.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH')
                 or shutil.which('chromium') or shutil.which('chromium-browser')
                 or shutil.which('google-chrome'))
 browser=pw.chromium.launch(executable_path=browser_path,headless=True)
 page=browser.new_page(viewport={'width':1440,'height':1000},device_scale_factor=1)
 page.on('pageerror',lambda e:errors.append(str(e)))
 page.on('request',lambda r:requests.append(r.url))
 page.set_content((ROOT/'index.html').read_text(),wait_until='load')
 def go(h):
  page.evaluate('(h)=>location.hash=h',h);page.wait_for_timeout(35)
 ck('默认入口为整体架构',page.locator('main').get_attribute('data-page')=='architecture')
 for n in D['nodes']:
  go('#/module/'+n['id'])
  ck('模块 '+n['id'],page.locator('h1').inner_text()==n['title'])
 for i in range(1,9):
  go('#/flow/'+str(i).zfill(2));ck('主流程步骤 '+str(i),page.locator('main').get_attribute('data-step')==str(i))
 for name in ('tools','failure','stop'):
  go('#/flow/'+name+'?at=06');ck('条件分支 '+name,page.locator('main').get_attribute('data-page')=='flow')
 for id in ('send','stream','history'):
  go('#/diagnostics/'+id);ck('问题定位 '+id,page.locator('main').get_attribute('data-page')=='diagnostics')
 go('#/capabilities');ck('全部 27 组条目',page.locator('.capability-card').count()==27)
 ck('27 个注册函数逐项唯一',len({c['registration'] for c in D['capabilities']['items']})==27)
 ck('21 个 apple 命令',sum(c['command'].startswith('apple-') for c in D['capabilities']['items'])==21)
 for group in D['capabilities']['groups']:
  go('#/capabilities?group='+group['id']);ck('分类 '+group['id'],page.locator('.capability-card').count()==sum(c['group']==group['id'] for c in D['capabilities']['items']))
 go('#/capabilities')
 page.locator('#capability-search').fill('照片');ck('关键词搜索 照片',page.locator('.capability-card').count()==1)
 page.locator('[data-clear-caps]').first.click();ck('清空搜索',page.locator('.capability-card').count()==27)
 for c in D['capabilities']['items']:
  go('#/capabilities?item='+c['id']);ck('可深链展开 '+c['id'],page.locator('#cap-'+c['id']).get_attribute('open') is not None)
 go('#/capabilities?tab=limits');ck('11 类重点边界',page.locator('.limit-card').count()==11)
 page.locator('#capability-search').fill('通讯录');ck('缺口搜索 通讯录',page.locator('.limit-card').count()==1)
 page.locator('[data-clear-caps]').first.click()
 # Read the chain in-context and return to the originating flow step.
 go('#/module/ish?from=%2Fflow%2Ftools%3Fat%3D06')
 page.locator('.native-chain a[href*="/module/native"]').click()
 ck('跨三模块保留流程来源', '/flow/tools?at=06' in page.locator('.back-context a').get_attribute('href'))
 page.get_by_role('link',name='打开完整清单 →').click()
 ck('清单保留原流程返回', '/flow/tools?at=06' in page.locator('.back-context a').get_attribute('href'))
 page.locator('.back-context a').click()
 ck('返回工具分支',page.locator('main').get_attribute('data-page')=='flow' and 'tools' in page.evaluate('location.hash'))
 # Crosswalk -> specific item -> module -> original catalogue item.
 go('#/module/os')
 page.locator('.framework-table a').filter(has_text='照片').first.click()
 ck('框架表定位照片能力',page.locator('#cap-photos').get_attribute('open') is not None)
 ck('能力项返回 OS',page.locator('.back-context a').get_attribute('href').startswith('#/module/os'))
 page.locator('#cap-photos .cap-item-actions a').filter(has_text='原生桥接').click()
 ck('清单进入模块后可返回条目','item=photos' in page.locator('.back-context a').get_attribute('href'))
 page.locator('.back-context a').click()
 ck('返回已展开条目',page.locator('#cap-photos').get_attribute('open') is not None)
 # Browser history with local hash transitions.
 go('#/module/ish');page.locator('.native-chain a[href*="/module/native"]').click()
 page.go_back();page.wait_for_timeout(60);ck('浏览器后退',page.locator('main').get_attribute('data-module')=='ish')
 page.go_forward();page.wait_for_timeout(60);ck('浏览器前进',page.locator('main').get_attribute('data-module')=='native')
 go('#/sources');ck('新增源码进入索引',page.locator('#source-index-list').inner_text().find('NativeOffloadUtils.m')>=0)
 # All outbound source links stay pinned to the analysis commit.
 refs=[]
 for c in D['capabilities']['items']:refs.extend(c['refs'])
 for c in D['capabilities']['gaps']:refs.extend(c['refs'])
 ck('所有原生清单引用有相对路径与说明',all(r.get('path') and r.get('symbol') for r in refs))
 page.locator('.source-grid details').evaluate_all('(els)=>els.forEach(e=>e.open=true)')
 links=page.locator('.ref').evaluate_all('(els)=>els.map(e=>e.href)')
 ck('源码链接固定 Commit',len(links)>0 and all(D['meta']['sha'] in l for l in links),len(links))
 # Keyboard: native HTML disclosure responds to Enter.
 go('#/capabilities');summary=page.locator('#cap-calendar>summary');summary.focus();page.keyboard.press('Enter')
 ck('键盘展开能力',page.locator('#cap-calendar').get_attribute('open') is not None)
 for width in (1440,1024,768,390,360):
  page.set_viewport_size({'width':width,'height':900})
  for h in ('#/architecture','#/module/ish','#/module/native','#/module/os','#/capabilities','#/capabilities?tab=limits','#/flow/06'):
   go(h);ck('视口宽度 %s %s'%(width,h),not page.evaluate('document.documentElement.scrollWidth>innerWidth'))
 # Each HTML is independently self-contained and enters its intended route.
 for f,expected in [('index.html','architecture'),('message-lifecycle.html','flow'),('mcp.html','module'),('native-capabilities.html','capabilities'),('ish.html','module'),('native.html','module'),('ios-frameworks.html','module')]:
  p=browser.new_page();p.on('pageerror',lambda e:errors.append(str(e)))
  p.set_content((ROOT/f).read_text(),wait_until='load');ck('独立入口 '+f,p.locator('main').get_attribute('data-page')==expected);p.close()
 ck('JavaScript 运行错误为零',not errors,errors)
 ck('页面展示无需外部资源请求',not requests,requests)
 browser.close()
report={'edition':'v3','baseline':D['meta']['sha'],'method':'Chromium / HTML set_content + hash navigation','passed':sum(c['passed'] for c in checks),'checks':checks,'errors':errors,'networkRequests':requests,'unavailable':['Direct file:// navigation excluded from this test; it was blocked by administrator policy in the original generation environment (ERR_BLOCKED_BY_ADMINISTRATOR)','Safari and physical-device browser validation','iOS build, native tool execution and real permissions/data verification'],'scope':'Static webpage interaction and data-structure validation only. Repository remains unchanged.'}
(ROOT/'validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print('PASSED',report['passed'],'checks')
