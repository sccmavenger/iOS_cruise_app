// Spike-only browser test page: two phones play Tic-Tac-Toe through the cloud room.
export const TEST_PAGE = `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CruiseLAN online test</title><style>
body{font:17px -apple-system,system-ui,sans-serif;max-width:420px;margin:20px auto;padding:0 16px;color:#0b1a3d}
button{font:inherit;padding:10px 14px;border-radius:10px;border:0;background:#05456f;color:#fff;margin:4px 0}
input{font:inherit;padding:10px;border-radius:10px;border:1px solid #9ab;width:9em;text-transform:uppercase}
#board{display:grid;grid-template-columns:repeat(3,90px);gap:6px;margin:16px 0}
#board button{height:90px;font-size:40px;background:#e8f1f7;color:#05456f}
#log{font:13px ui-monospace,monospace;white-space:pre-wrap;background:#f4f6f8;padding:8px;border-radius:8px;max-height:220px;overflow:auto}
.big{font-size:28px;font-weight:700;letter-spacing:2px}</style></head><body>
<h2>CruiseLAN online test</h2>
<div id="start"><button onclick="create()">New Tic-Tac-Toe room</button><br>or join: <input id="code" placeholder="CODE"> <button onclick="join()">Join</button></div>
<div id="game" hidden><div>Room <span id="room" class="big"></span> · you are <b id="me"></b></div>
<div id="status"></div><div id="board"></div><button onclick="rematchHint()">How to retest</button></div>
<h4>Connection</h4><div id="net"></div><div id="log"></div>
<script>
const $=(id)=>document.getElementById(id), log=(t)=>{$("log").textContent=new Date().toLocaleTimeString()+" "+t+"\\n"+$("log").textContent};
let ws, room, token, seat, view, revision=-1, pings=[];
async function api(path, body){const r=await fetch(path,{method:"POST",body:JSON.stringify(body)});return r.json()}
async function create(){const r=await api("/rooms",{game:"ticTacToe",nickname:"A"});enter(r)}
async function join(){const r=await api("/rooms/"+$("code").value.trim().toUpperCase()+"/join",{nickname:"B"});if(r.error)return alert(r.error);enter(r)}
function enter(r){room=r.code;token=r.token;seat=r.seat;localStorage.setItem("cruiselan-test",JSON.stringify(r));$("start").hidden=true;$("game").hidden=false;$("room").textContent=room;$("me").textContent=seat==="seat0"?"X":"O";connect()}
function connect(){const t0=performance.now();ws=new WebSocket(location.origin.replace("http","ws")+"/rooms/"+room+"/socket?token="+token);
 ws.onopen=()=>{log("connected in "+Math.round(performance.now()-t0)+" ms");ws.send(JSON.stringify({type:"resume"}))};
 ws.onclose=(e)=>{log("disconnected (code "+e.code+"), reconnecting…");setTimeout(connect,1000)};
 ws.onmessage=(e)=>{const m=JSON.parse(e.data);
  if(m.type==="snapshot"&&m.revision>=revision){revision=m.revision;view=m.view.ticTacToe._0;draw()}
  if(m.type==="lobby")$("status").textContent="Share code "+room+" — waiting for player 2";
  if(m.type==="result"){const ms=Math.round(performance.now()-sent[m.moveId]);log((m.ok?"move ok":"refused: "+m.error)+" — round trip "+ms+" ms")}
  if(m.type==="pong"){pings.push(performance.now()-m.t);if(pings.length>20)pings.shift();const s=[...pings].sort((a,b)=>a-b);$("net").textContent="ping now "+Math.round(pings.at(-1))+" ms · median "+Math.round(s[s.length>>1])+" ms"}}}
setInterval(()=>{if(ws&&ws.readyState===1)ws.send(JSON.stringify({type:"ping",t:performance.now()}))},3000);
const sent={};
function play(cell){const id=crypto.randomUUID();sent[id]=performance.now();ws.send(JSON.stringify({type:"move",moveId:id,baseRevision:revision,move:{ticTacToe:{cell}}}))}
function draw(){const b=$("board");b.innerHTML="";view.board.forEach((v,i)=>{const x=document.createElement("button");x.textContent=v==="x"?"X":v==="o"?"O":"";x.onclick=()=>play(i);b.appendChild(x)});
 const mine=(seat==="seat0"?"x":"o"), o=view.outcome;$("status").textContent=o?("Game over: "+JSON.stringify(o)):(view.turn===mine?"Your turn":"Their turn")+" · revision "+revision}
function rematchHint(){alert("Try: turn Wi-Fi off on one phone mid-game, or lock it for a minute, then come back. The board should be exactly where you left it.")}
const saved=localStorage.getItem("cruiselan-test");if(saved&&location.hash!=="#new"){const r=JSON.parse(saved);if(confirm("Rejoin room "+r.code+"?"))enter(r)}
</script></body></html>`;
