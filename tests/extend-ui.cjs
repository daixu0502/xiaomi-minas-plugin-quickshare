// Synthetic records/API, no access to real shares or NAS mutations.
const {chromium}=require('playwright');
const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const ui=path.resolve(__dirname,'../payload/ui');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.EDGE_PATH||'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'});
 try{for(const profile of [{name:'desktop',w:870,h:526},{name:'small',w:480,h:320},{name:'narrow',w:320,h:460},{name:'android-dark',w:390,h:844,mobile:true,dark:true},{name:'ios-light',w:390,h:844,mobile:true}]){
  const context=await browser.newContext({viewport:profile.mobile?{width:profile.w,height:profile.h}:{width:1280,height:900},hasTouch:!!profile.mobile,isMobile:!!profile.mobile,colorScheme:profile.dark?'dark':'light',userAgent:profile.mobile?(profile.dark?'Android Mobile':'iPhone Mobile Safari'):'SmartStorage Electron/35'});
  const page=await context.newPage(),errors=[],calls=[];let reject=true;
  page.on('pageerror',e=>errors.push(e.message));
  if(!profile.mobile)await page.addInitScript(()=>window.__MICRO_APP_ENVIRONMENT__=true);
  const now=Math.floor(Date.now()/1000),base={kind:'download',path:'data/example.txt',password_protected:true,uses:1,max_uses:5,url:'https://share.example.test/s/unchanged-token',expires_at:now+3600};
  const shares=[{...base,id:'active',name:'有效分享',status:'active'},{...base,id:'expired',name:'过期分享',status:'expired',expires_at:now-1000},{...base,id:'revoked',name:'手动失效',status:'revoked'},{...base,id:'exhausted',name:'次数用完',status:'exhausted',uses:5}];
  await page.exposeFunction('shareFixture',async q=>{
   calls.push(q);
   if(q.action==='status')return {ok:true,running:true,baseUrl:'https://share.example.test',pluginVersion:'1.1.31',activeShares:1,totalShares:4};
   if(q.action==='list')return {ok:true,shares};
   if(q.action==='settings_get')return {ok:true,externalBase:'',lanUrl:'http://192.0.2.1:19092'};
   if(q.action==='extend'){
    await new Promise(r=>setTimeout(r,180));if(reject){reject=false;return {ok:false,error:'模拟保存失败，请稍后重试'};}
    const record=shares.find(s=>s.id===q.data.id);assert.equal(q.data.expectedExpiresAt,record.expires_at);
    record.expires_at=Math.max(record.expires_at,Math.floor(Date.now()/1000))+q.data.seconds;record.status='active';return {ok:true,share:record};
   }
   throw Error('Unexpected action '+q.action);
  });
  await page.route('**/*',route=>{
   const name=path.basename(new URL(route.request().url()).pathname)||'index.html';if(!/^[\w.-]+$/.test(name)||!fs.existsSync(path.join(ui,name)))return route.abort();
   let body=fs.readFileSync(path.join(ui,name),'utf8');
   if(name==='client-bridge.js')body+='\nwindow.XiaomiPluginClient.request=async q=>new Response(JSON.stringify(await window.shareFixture({action:q.action,data:JSON.parse(q.options.body||"{}")})));';
   if(name==='index.html'&&!profile.mobile)body=body.replace('<body>',`<body style="margin:0;height:100vh"><micro-app style="display:block;position:absolute;left:90px;top:140px;width:${profile.w}px;height:${profile.h}px">`).replace('</body>','</micro-app></body>');
   return route.fulfill({body,contentType:name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':'text/html'});
  });
  await page.goto('http://share-extension.test/index.html');await page.locator('.tab[data-page=records]').click();
  const card=name=>page.locator('.share-card').filter({has:page.locator('h3',{hasText:name})});
  await card('有效分享').getByRole('button',{name:'延期',exact:true}).click();
  await page.waitForTimeout(200);
  const dialog=page.locator('#extendModal');
  const rect=await dialog.boundingBox(),boundary=profile.mobile?{x:0,y:0,width:profile.w,height:profile.h}:await page.locator('.desktop-frame').boundingBox();
  assert(rect.x>=boundary.x-1&&rect.y>=boundary.y-1&&rect.x+rect.width<=boundary.x+boundary.width+1&&rect.y+rect.height<=boundary.y+boundary.height+1,'dialog outside window');
  assert(await dialog.evaluate(e=>e.scrollWidth<=e.clientWidth+1),'horizontal overflow');
  assert(await page.locator('#extendSave').evaluate(e=>{const r=e.getBoundingClientRect(),d=e.closest('.dialog').getBoundingClientRect();return r.top>=d.top&&r.bottom<=d.bottom}),'confirmation button clipped');
  if(process.env.EXTEND_SCREENSHOT_DIR){fs.mkdirSync(process.env.EXTEND_SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.EXTEND_SCREENSHOT_DIR,profile.name+'.png')});}
  assert.equal(await page.locator('input[name=extendSeconds]:checked').inputValue(),'86400');
  await page.locator('#extendCancel').click();assert.equal(calls.filter(q=>q.action==='extend').length,0);
  await card('有效分享').getByRole('button',{name:'延期',exact:true}).click();
  await page.locator('#extendForm').evaluate(e=>{e.requestSubmit();e.requestSubmit()});
  assert(await page.locator('#extendSave').isDisabled());await page.keyboard.press('Escape');assert(await dialog.isVisible(),'busy modal closed');
  await page.locator('#extendError').filter({hasText:'模拟保存失败'}).waitFor();
  assert.equal(calls.filter(q=>q.action==='extend').length,1,'double submit');
  await page.locator('#extendSave').click();await dialog.waitFor({state:'hidden'});
  assert.equal(shares[0].expires_at,base.expires_at+86400);assert.equal(shares[0].url,base.url);assert.equal(shares[0].uses,1);
  await card('过期分享').getByRole('button',{name:'延期',exact:true}).click();
  await page.locator('input[name=extendSeconds][value="604800"]').check();
  await page.locator('#extendSave').click();await dialog.waitFor({state:'hidden'});
  assert(Math.abs(shares[1].expires_at-(Math.floor(Date.now()/1000)+604800))<3,'expired share not extended from now');
  assert.equal(await card('手动失效').getByRole('button',{name:'延期',exact:true}).count(),0);
  assert.equal(await card('次数用完').getByRole('button',{name:'延期',exact:true}).count(),0);
  assert.equal(errors.length,0,errors.join('\n'));
  console.log('PASS '+profile.name+': expiry rules, cancel, inline error, retry, busy guard, unchanged URL/count, boundaries');
  await context.close();
 }}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
