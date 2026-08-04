#!/bin/bash
# Station — builds everything from the HTML files already in this folder.
# Run inside the Docker container:   bash setup-station.sh
set -e

APP=/root/station-app
echo "==> Preparing $APP"
mkdir -p "$APP/public"

# --- take the pages from wherever they are ---
FOUND=0
for f in index.html tasks.html calendar.html contacts.html notes.html habits.html items.html money.html vault.html; do
  if [ -f "$f" ]; then cp "$f" "$APP/public/"; FOUND=$((FOUND+1)); fi
done
if [ "$FOUND" -lt 9 ]; then
  echo "STOPPED: only found $FOUND of 9 pages. Run this from the folder with the .html files in it."
  exit 1
fi
echo "    $FOUND pages copied"

# --- point them at the server instead of the chat window ---
echo "==> Switching the pages over to server storage"
python3 - "$APP/public" <<'PYEOF'
import sys, glob, os
OLD = '''var DB={
  ok:!!(window.storage&&window.storage.get),
  async get(k){ if(!this.ok) return null;
    try{ var r=await window.storage.get(k); return (r&&r.value)?JSON.parse(r.value):null; }
    catch(e){ return null; } },
  async set(k,v){ if(!this.ok) return false;
    try{ await window.storage.set(k,JSON.stringify(v)); return true; }
    catch(e){ return false; } }
};'''
NEW = '''var DB={
  ok:true,
  async get(k){
    try{
      var r=await fetch("/api/kv/"+encodeURIComponent(k),{credentials:"same-origin"});
      if(r.status===404) return null;
      if(!r.ok) throw new Error(r.status);
      return (await r.json()).value;
    }catch(e){ console.error("read failed",k,e); DB.ok=false; return null; }
  },
  async set(k,v){
    try{
      var r=await fetch("/api/kv/"+encodeURIComponent(k),{
        method:"PUT",credentials:"same-origin",
        headers:{"Content-Type":"application/json"},
        body:JSON.stringify({value:v})});
      if(!r.ok) throw new Error(r.status);
      return true;
    }catch(e){ console.error("write failed",k,e); return false; }
  }
};'''
d = sys.argv[1]
done = 0
for p in sorted(glob.glob(os.path.join(d, "*.html"))):
    s = open(p).read()
    if OLD in s:
        open(p, "w").write(s.replace(OLD, NEW))
        done += 1
    elif '"/api/kv/"' in s:
        done += 1
    else:
        print("    WARNING: couldn't patch", os.path.basename(p))
print(f"    {done} pages now talk to the server")
PYEOF

# --- the server ---
echo "==> Writing the server"
cat > "$APP/server.js" <<'JSEOF'
const http=require("http"),fs=require("fs"),path=require("path"),crypto=require("crypto");
const PORT=process.env.STATION_PORT||8099, HOST=process.env.STATION_HOST||"0.0.0.0";
const DATA=process.env.STATION_DATA||"/data", PUB=process.env.STATION_PUBLIC||path.join(__dirname,"public");
const MAX=8*1024*1024;
fs.mkdirSync(DATA,{recursive:true});
const T={".html":"text/html; charset=utf-8",".js":"text/javascript; charset=utf-8",".css":"text/css",".json":"application/json",".svg":"image/svg+xml",".png":"image/png",".ico":"image/x-icon"};
const keyFile=k=>/^[A-Za-z0-9:_.-]{1,120}$/.test(k)?path.join(DATA,k.replace(/:/g,"_")+".json"):null;
const send=(res,c,b,t)=>{res.writeHead(c,{"Content-Type":t||"application/json; charset=utf-8","Cache-Control":"no-store","X-Content-Type-Options":"nosniff"});res.end(b);};
const readBody=req=>new Promise(r=>{let n=0,over=false;const c=[];
  req.on("data",d=>{if(over)return;n+=d.length;if(n>MAX){over=true;c.length=0;return;}c.push(d);});
  req.on("end",()=>r(over?null:Buffer.concat(c).toString("utf8")));req.on("error",()=>r(null));});
function writeAtomic(f,t){const tmp=f+"."+crypto.randomBytes(6).toString("hex")+".tmp";
  const fd=fs.openSync(tmp,"w");try{fs.writeSync(fd,t);fs.fsyncSync(fd);}finally{fs.closeSync(fd);}fs.renameSync(tmp,f);}
http.createServer(async(req,res)=>{
  const u=req.url.split("?")[0];
  if(u==="/api/health") return send(res,200,JSON.stringify({ok:true,time:Date.now()}));
  if(u==="/api/keys"&&req.method==="GET")
    return send(res,200,JSON.stringify({keys:fs.readdirSync(DATA).filter(f=>f.endsWith(".json")).map(f=>f.slice(0,-5).replace(/_/g,":"))}));
  if(u.startsWith("/api/kv/")){
    const key=decodeURIComponent(u.slice(8)), file=keyFile(key);
    if(!file) return send(res,400,JSON.stringify({error:"bad key"}));
    if(req.method==="GET"){
      if(!fs.existsSync(file)) return send(res,404,JSON.stringify({error:"not found"}));
      try{return send(res,200,fs.readFileSync(file,"utf8"));}catch(e){return send(res,500,JSON.stringify({error:"read failed"}));}
    }
    if(req.method==="PUT"){
      const raw=await readBody(req);
      if(raw===null) return send(res,413,JSON.stringify({error:"too large"}));
      let p;try{p=JSON.parse(raw);}catch(e){return send(res,400,JSON.stringify({error:"bad json"}));}
      if(!("value" in p)) return send(res,400,JSON.stringify({error:"missing value"}));
      try{writeAtomic(file,JSON.stringify({key,value:p.value,updated:Date.now()}));}
      catch(e){return send(res,500,JSON.stringify({error:"write failed"}));}
      return send(res,200,JSON.stringify({key,ok:true}));
    }
    if(req.method==="DELETE"){
      try{if(fs.existsSync(file))fs.unlinkSync(file);}catch(e){return send(res,500,JSON.stringify({error:"delete failed"}));}
      return send(res,200,JSON.stringify({key,deleted:true}));
    }
    return send(res,405,JSON.stringify({error:"method not allowed"}));
  }
  if(req.method==="GET"){
    let rel=decodeURIComponent(u); if(rel==="/") rel="/index.html";
    const f=path.join(PUB,path.normalize(rel));
    if(!f.startsWith(PUB)) return send(res,403,"forbidden","text/plain");
    return fs.readFile(f,(e,b)=>e?send(res,404,"not found","text/plain"):send(res,200,b,T[path.extname(f)]||"application/octet-stream"));
  }
  send(res,404,JSON.stringify({error:"not found"}));
}).listen(PORT,HOST,()=>console.log("station on "+HOST+":"+PORT+"  data:"+DATA));
JSEOF

# --- container definition ---
cat > "$APP/Dockerfile" <<'DEOF'
FROM node:20-alpine
WORKDIR /app
COPY server.js /app/server.js
COPY public /app/public
RUN addgroup -S station && adduser -S station -G station \
 && mkdir -p /data && chown -R station:station /data /app
USER station
ENV STATION_DATA=/data STATION_PUBLIC=/app/public STATION_HOST=0.0.0.0 STATION_PORT=8099
EXPOSE 8099
CMD ["node","/app/server.js"]
DEOF

cat > "$APP/docker-compose.yml" <<'CEOF'
services:
  station:
    build: .
    container_name: station
    restart: unless-stopped
    ports:
      - "8099:8099"
    volumes:
      - station-data:/data
volumes:
  station-data:
CEOF
echo "    server, Dockerfile and compose file written"

# --- build and run ---
echo "==> Building (a few minutes the first time)"
cd "$APP"
docker compose up -d --build

echo "==> Checking it answers"
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8099/api/health >/dev/null 2>&1; then
    echo "    $(curl -s http://127.0.0.1:8099/api/health)"
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo "==================================="
    echo "  Station is running."
    echo "  Open:  http://$IP:8099"
    echo "==================================="
    echo ""
    echo "  Next, for the password vault:"
    echo "     tailscale up"
    echo "     tailscale serve --bg 8099"
    exit 0
  fi
  sleep 2
done
echo "STOPPED: it built but never answered. Run:  docker logs station"
exit 1
