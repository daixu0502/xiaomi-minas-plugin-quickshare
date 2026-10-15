// Isolated clipboard regression. No NAS requests and no system clipboard writes.
const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const {chromium}=require('playwright');
const ui=path.resolve(__dirname,'../payload/ui');
const cases=[
 {name:'desktop-focus-rejected',desktop:true,legacy:'ok',modern:'reject'},
 {name:'desktop-host-style',desktop:true,legacy:'ok',modern:'reject',hostStyles:true},
 {name:'desktop-modern-fallback',desktop:true,legacy:'false',modern:'ok'},
 {name:'desktop-manual',desktop:true,legacy:'false',modern:'reject',manual:true},
 {name:'desktop-exceptions',desktop:true,legacy:'throw',modern:'throw',manual:true},
 {name:'desktop-success-then-denied',desktop:true,legacy:'ok',modern:'reject',recordManual:true},
 {name:'mobile-modern',legacy:'false',modern:'ok'},
 {name:'mobile-dark',legacy:'false',modern:'ok',dark:true},
 {name:'mobile-fallback',legacy:'ok',modern:'reject'},
 {name:'mobile-manual',legacy:'false',modern:'reject',manual:true},
 {name:'http-legacy',desktop:true,legacy:'ok',modern:'reject',http:true}
];
const shareUrl='https://share.example.test/s/clipboard-test-link';
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.EDGE_PATH});
 try{for(const profile of cases.filter(item=>!process.env.QUICKSHARE_CASE||item.name===process.env.QUICKSHARE_CASE)){
  const context=await browser.newContext({viewport:profile.desktop?{width:870,height:600}:{width:390,height:844},colorScheme:profile.dark?'dark':'light',isMobile:!profile.desktop,hasTouch:!profile.desktop,userAgent:profile.desktop?'SmartStorage Electron/30':'Mozilla/5.0 Android Mobile Chrome'});
  await context.addInitScript(policy=>{
   window.__copies={modern:[],legacy:[],selected:[]};window.__copyPolicy=policy;
   const nativeDoc=document;
   Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText(value){window.__copies.modern.push(value);if(policy.modern==='throw')throw new DOMException('Document is not focused.','NotAllowedError');return policy.modern==='ok'?Promise.resolve():Promise.reject(new DOMException('Document is not focused.','NotAllowedError'));}}});
   nativeDoc.execCommand=function(command){
    const field=nativeDoc.activeElement;window.__copies.legacy.push(command);
    window.__copies.selected.push(field&&field.value&&field.value.slice(field.selectionStart,field.selectionEnd));
    if(policy.legacy==='throw')throw new Error('legacy copy unavailable');
    return policy.legacy==='ok';
   };
   if(policy.desktop){window.__MICRO_APP_ENVIRONMENT__=true;let listener;window.microApp={addDataListener(fn){listener=fn;},removeDataListener(){},dispatch(){setTimeout(()=>listener({data:{cgiPort:1234,cgiToken:'test-auth'}}),0);}};}
  },profile);
  const page=await context.newPage(),errors=[];let creates=0;
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*',async route=>{
   const request=route.request(),url=new URL(request.url()),name=path.basename(url.pathname);
   if(name==='quickshare.cgi'){
    if(profile.desktop)assert.equal(request.headers().authorization,'test-auth');
    const action=url.searchParams.get('action');let result={ok:true};
    const existing={id:'existing',url:shareUrl,name:'example.txt',path:'data/example.txt',kind:'download',status:'active',uses:0,max_uses:3,expires_at:1893456000};
    if(action==='status')Object.assign(result,{running:true,pluginVersion:'1.1.28',baseUrl:'https://share.example.test',activeShares:1,totalShares:1});
    else if(action==='list')result.shares=[existing];
    else if(action==='settings_get')Object.assign(result,{externalBase:'',lanUrl:'http://192.0.2.1:19092'});
    else if(action==='browse')Object.assign(result,{path:'data',entries:[{type:'file',name:'example.txt',path:'data/example.txt',size:12}]});
    else if(action==='create'){creates++;result.share=existing;}
    else throw new Error('Unexpected API action '+action);
    return route.fulfill({json:result});
   }
   if(!/^(index\.html|[\w-]+\.(css|js))$/.test(name))return route.abort();
   let body=fs.readFileSync(path.join(ui,name),'utf8');
   if(name==='index.html')body=body.replace('<body>','<body><style>html,body{height:100%;margin:0}'+(profile.hostStyles?'.share-actions button{color:#18785c!important}':'')+'</style>');
   if(name==='app.js')body='window.XiaomiPluginClient.document=new Proxy(window.XiaomiPluginClient.document,{get:function(t,k){if(k==="execCommand")return function(){throw Error("Use the node ownerDocument");};return t[k];}});\n'+body;
   return route.fulfill({body,contentType:name.endsWith('.css')?'text/css':name.endsWith('.js')?'application/javascript':'text/html'});
  });
  await page.goto((profile.http?'http:':'https:')+'//quickshare-ui.test/index.html');
  await page.waitForFunction(()=>document.querySelector('#version').textContent==='插件版本 1.1.28');
  await page.locator('#browseButton').click();await page.locator('.file-row').click();await page.locator('#createButton').click();
  await page.locator('#linkModal').waitFor({state:'visible'});
  assert.equal(await page.locator('#createdLink').inputValue(),shareUrl);
  await page.locator('#copyCreatedLink').click();
  if(profile.manual){
   await page.locator('#copyHelp').waitFor({state:'visible'});
   assert((await page.locator('#copyHelp').innerText()).includes('Ctrl+C'));
   assert(await page.locator('#createdLink').evaluate(e=>e.ownerDocument.activeElement===e&&e.selectionStart===0&&e.selectionEnd===e.value.length));
   const box=await page.locator('#linkModal').boundingBox();assert(box.y>=0&&box.y+box.height<=(profile.desktop?600:844),'Manual copy dialog must stay inside the client window');
   assert(!((await page.locator('#toast').innerText()).includes('已复制')));
   if(process.env.QUICKSHARE_SCREENSHOT_DIR&&profile.name==='desktop-manual'){
    fs.mkdirSync(process.env.QUICKSHARE_SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.QUICKSHARE_SCREENSHOT_DIR,'desktop-manual.png'),animations:'disabled'});
   }
   await page.locator('#closeLink').click();
  }else{
   await page.locator('#linkModal').waitFor({state:'hidden'});
   assert.equal(await page.locator('#toast').innerText(),'链接已复制');
  }
  assert.equal(creates,1);
  assert(!((await page.locator('body').innerText()).includes('Document is not focused')));
  if(profile.recordManual)await page.evaluate(()=>{window.__copyPolicy.legacy='false';window.__copyPolicy.modern='reject';});
  await page.locator('.tab[data-page=records]').click();
  const actions=page.locator('.share-actions').first();
  await actions.locator('a').waitFor();
  const typography=await actions.locator('button,a').evaluateAll(items=>items.map(e=>{const s=getComputedStyle(e);return {font:s.fontFamily,size:s.fontSize,weight:s.fontWeight,line:s.lineHeight,padding:s.padding,border:s.borderRadius,height:e.getBoundingClientRect().height};}));
  assert.equal(typography.length,5);for(const style of typography){const {height,...text}=style,{height:referenceHeight,...referenceText}=typography[0];assert.deepEqual(text,referenceText,'Action controls must use the same font and spacing');assert(Math.abs(height-referenceHeight)<0.5,'Action controls must have the same visual height');}
  assert.equal(typography[0].size,'14px');assert.equal(typography[0].weight,'600');assert(typography[0].height>=40);
  const colors=await actions.evaluate(e=>{const probe=e.ownerDocument.createElement('span');e.append(probe);probe.style.color='var(--red)';const red=getComputedStyle(probe).color;probe.remove();return {red,actions:[...e.children].map(x=>getComputedStyle(x).color)};});
  assert.equal(await actions.locator('.quickshare-danger-action').count(),2);
  assert.equal(colors.actions[3],colors.red,'Revoke must stay red under client button styles');assert.equal(colors.actions[4],colors.red,'Delete must stay red under client button styles');
  assert.notEqual(colors.actions[0],colors.red);assert.notEqual(colors.actions[1],colors.red);assert.notEqual(colors.actions[2],colors.red);
  assert.equal(await actions.locator('a').getAttribute('href'),shareUrl);assert.equal(await actions.locator('a').getAttribute('target'),'_blank');
  if(process.env.QUICKSHARE_SCREENSHOT_DIR&&profile.name==='desktop-focus-rejected'){fs.mkdirSync(process.env.QUICKSHARE_SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.QUICKSHARE_SCREENSHOT_DIR,'record-actions-desktop.png')});}
  await page.locator('.share-actions button').first().click();
  if(profile.manual||profile.recordManual){await page.locator('#copyHelp').waitFor({state:'visible'});assert.equal(await page.locator('#createdLink').inputValue(),shareUrl);assert.equal(await page.locator('#linkTitle').innerText(),'复制分享链接');assert.equal(await page.locator('#toast').innerText(),'');}
  else{await page.waitForFunction(()=>document.querySelector('#toast').textContent==='链接已复制');assert(await page.locator('#linkModal').isHidden());}
  assert.equal(creates,1,'Copying an existing record must not create another share');
  assert.equal(await page.locator('.minas-plugin-body textarea').count(),1,'Temporary copy fields must be removed');
  const calls=await page.evaluate(()=>window.__copies);
  if(profile.name==='desktop-focus-rejected')assert.equal(calls.modern.length,0);
  if(profile.name==='mobile-fallback'){assert(calls.modern.length>0);assert(calls.legacy.length>0);}
  if(profile.legacy==='ok')assert(calls.selected.every(value=>value===shareUrl));
  assert.deepEqual(errors,[]);
  console.log(profile.name+': created link / record copy / selection / cleanup passed');
  await context.close();
 }}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
