# Live validation methods

These are the final harnesses used on the isolated local lab. Paths identify the scratch environment of this run; adapt them for a new checkout. They are retained as experiment transcripts, outside automatic CI. Plain-text log copies remove terminal colour escapes and trailing whitespace; numeric values and failure outcomes are preserved. The collector TXT selects final batches containing all four inference stages; its gzip archive retains the full normalized capture. Never substitute production resources for these `blueprint-phase8-*` containers/namespaces.

Order: reconstruct Phase 7 Runway; copy the Phase 8 gateway and API adapter into it; build the API/IDP image; start the synthetic issuer, Redis, model, collector and Prometheus; run the API checks and game day; build the release-bound model image; install the pinned Sigstore controller and TLS local registry; run admission, Kubernetes and weight/webhook checks; install the official Prometheus adapter; run HPA, in-cluster API routing and startup checks. Run Ray and network training separately. Each harness asserts its evidence before writing a passing result.

The initial model release's signed public artifacts are in [the CPU bundle](../2026-11-07/report.md). Its private signer has been removed; only its public key and valid bundle are reused. The new image signer is a separate ephemeral lab key. Neither kubeconfig, bearer tokens, private signing keys nor weights are in this evidence directory.

The model image uses the pinned upstream server plus the launcher in Step 7, Cosign, public model key and public Sigstore trust root. `expectedManifest` is compiled in. It is signed by the lab image key. Registry CA trust is installed only in the isolated node and controller. The adapter uses a private lab CA; the aggregation API verifies it. Prometheus scrapes the actual host API and adds constant namespace/service labels for the represented gateway Service. A selectorless Service and EndpointSlice route to that API through a Docker-bridge-bound proxy. The API calls the Kubernetes model NodePort, so it can reach both backend replicas; port-forwarding a Service would select only one pod.

The network harness puts two CPU/Gloo ranks on a dedicated Docker bridge, with `tc` in NET_ADMIN sidecars sharing only those containers' network namespaces. It never modifies the host/default interface. It checkpoints model, optimizer/momentum, step, RNG and dataset seed before failure. Partition occurs only after both ranks acknowledge the checkpoint; actual packet drops and bounded process exits are retained. Restore qdiscs before resuming. These are two container network namespaces on one host, not independent physical hosts or RDMA.

## Synthetic issuer and actual API

~~~python
import json,os,secrets,subprocess,time,urllib.request,urllib.parse
from pathlib import Path
root=Path('/tmp/blueprint-phase8-platform')
clients={'acme':('acme-client',secrets.token_urlsafe(32),'acme','generator+submitter+reader'),
         'hooli':('hooli-client',secrets.token_urlsafe(32),'hooli','generator+submitter+reader'),
         'reader':('reader-client',secrets.token_urlsafe(32),'acme','reader')}
issuer='http://127.0.0.1:18082'
env={**os.environ,'IDP_ISSUER':issuer,'IDP_AUDIENCE':'runway','IDP_KEYS':str(root/'idp-keys'),'IDP_CREATE_KEY':'true','LISTEN_ADDR':'127.0.0.1:18082','IDP_CLIENTS':','.join(':'.join(row) for row in clients.values()),'IDP_TOKEN_LIFETIME':'1h'}
env['IDP_KEYS']='/tmp/idp-keys'
command=['docker','run','-d','--name','blueprint-phase8-idp','--network','host','--entrypoint','/usr/local/bin/idp']
for k in ('IDP_ISSUER','IDP_AUDIENCE','IDP_KEYS','IDP_CREATE_KEY','LISTEN_ADDR','IDP_CLIENTS','IDP_TOKEN_LIFETIME'):command+=['-e',k+'='+env[k]]
command+=['blueprint-phase8-api:validation']
subprocess.run(command,check=True,capture_output=True)
for _ in range(100):
 try:
  urllib.request.urlopen(issuer+'/.well-known/jwks.json',timeout=1).close();break
 except OSError:time.sleep(.1)
else:raise RuntimeError('idp not ready')
api_env={**os.environ,'AUTH_MODE':'required','AUTH_ISSUER':issuer,'AUTH_AUDIENCE':'runway','LISTEN_ADDR':'127.0.0.1:18081','GRPC_ADDR':'127.0.0.1:18083','RATE_LIMIT':'off','INFERENCE_UPSTREAM':'http://127.0.0.1:18080','INFERENCE_REDIS_ADDR':'127.0.0.1:16379','INFERENCE_TOKEN_BUDGET':'50000','INFERENCE_SLOTS':'1','INFERENCE_QUEUE':'8','OTEL_EXPORTER_OTLP_ENDPOINT':'http://127.0.0.1:14318'}
command=['docker','run','-d','--name','blueprint-phase8-api','--network','host']
for k in ('AUTH_MODE','AUTH_ISSUER','AUTH_AUDIENCE','LISTEN_ADDR','GRPC_ADDR','RATE_LIMIT','INFERENCE_UPSTREAM','INFERENCE_REDIS_ADDR','INFERENCE_TOKEN_BUDGET','INFERENCE_SLOTS','INFERENCE_QUEUE','OTEL_EXPORTER_OTLP_ENDPOINT'):command+=['-e',k+'='+api_env[k]]
command+=['blueprint-phase8-api:validation']
subprocess.run(command,check=True,capture_output=True)
for _ in range(100):
 try:
  urllib.request.urlopen('http://127.0.0.1:18081/ready',timeout=1).close();break
 except OSError:time.sleep(.1)
else:raise RuntimeError('API not ready')
tokens={}
for name,(client,secret,*_) in clients.items():
 req=urllib.request.Request(issuer+'/token',data=urllib.parse.urlencode({'grant_type':'client_credentials'}).encode())
 import base64
 req.add_header('Authorization','Basic '+base64.b64encode((client+':'+secret).encode()).decode())
 with urllib.request.urlopen(req,timeout=5) as response:tokens[name]=json.load(response)['access_token']
private=root/'access.private.json'
private.write_text(json.dumps({'tokens':tokens,'api_container':'blueprint-phase8-api','idp_container':'blueprint-phase8-idp'}));private.chmod(0o600)
print('Actual API and IDP started; synthetic credentials kept only in /tmp access.private.json.')
~~~

## API routing/telemetry assertions

~~~python
import json,os,sys,time,urllib.request,urllib.error,urllib.parse,subprocess
from dataclasses import asdict
from pathlib import Path
sys.path.insert(0,'/tmp/blueprint-phase8-live/serve/src')
from serve.stream import chat
root=Path('/tmp/blueprint-phase8-platform');tokens=json.loads((root/'access.private.json').read_text())['tokens']
out=Path('/home/techieemma/projects/Nicholas-Engineering-Blueprint/lessons/08-ai-infrastructure/evidence/platform-validation')
url='http://127.0.0.1:18081'
records=[]
def request(method,path,body=None,token=None):
 req=urllib.request.Request(url+path,data=json.dumps(body).encode() if body is not None else None,method=method,headers={'Content-Type':'application/json','X-Tenant':'spoofed'})
 if token:req.add_header('Authorization','Bearer '+token)
 try:
  with urllib.request.urlopen(req,timeout=35) as response:return response.status,response.read().decode()
 except urllib.error.HTTPError as e:return e.code,e.read().decode()
body={'messages':[{'role':'user','content':'Reply with river only.'}],'max_tokens':8,'stream':True}
for who,want in [('none',401),('reader',403),('acme',200),('hooli',200)]:
 status,reply=request('POST','/v1/chat/completions',body,tokens.get(who))
 assert status==want,(who,status,reply)
 if status==200:assert '[DONE]' in reply
 records.append({'case':who,'status':status,'expected':want,'complete':'[DONE]' in reply})
status,reply=request('POST','/jobs',{'description':'phase8-job-compatibility','duration_ms':10},tokens['acme'])
assert status==201,(status,reply)
job=json.loads(reply)
status,_=request('GET','/jobs/'+str(job['id']),token=tokens['hooli']);assert status==404,status
records.append({'case':'existing jobs route and cross-tenant read','created_status':201,'other_tenant_status':status})
os.environ['RUNWAY_TOKEN']=tokens['acme']
rows=[asdict(chat(url,f'Probe {i}: reply with river only.',8)) for i in range(10)]
assert all(not r['error'] and r['output_tokens'] is not None for r in rows),rows
os.environ.pop('RUNWAY_TOKEN')
time.sleep(4)
metrics=urllib.request.urlopen(url+'/metrics',timeout=5).read().decode()
for name in ('inference_outcomes_total','inference_good_total','inference_first_content_seconds_bucket','inference_queue_seconds_bucket','inference_active','inference_waiting','inference_output_tokens_total'):
 assert name in metrics,name
query=urllib.parse.urlencode({'query':'sum(inference_outcomes_total{outcome="complete"})'})
result=json.load(urllib.request.urlopen('http://127.0.0.1:19090/api/v1/query?'+query,timeout=5))
assert result['status']=='success' and result['data']['result'],result
traces=subprocess.check_output(['docker','logs','blueprint-phase8-collector'],stderr=subprocess.STDOUT,text=True)
for name in ('inference.queue','inference.tokenize','inference.reserve','inference.backend_stream'):
 assert name in traces,name
for token in tokens.values():
 assert token not in metrics and token not in traces,'credential in telemetry'
assert 'Reply with river only' not in traces,'prompt in telemetry'
(out/'api-checks.json').write_text(json.dumps(records,indent=2)+'\n')
(out/'api-probes.json').write_text(json.dumps(rows,indent=2)+'\n')
(out/'api-metrics.txt').write_text(metrics)
(out/'prometheus-query.json').write_text(json.dumps(result,indent=2)+'\n')
(out/'collector-traces.txt').write_text(traces)
print('Live API: 401/403/200, tenants, existing jobs, ten completed probes, Prometheus scrape/query and OTLP stages passed; no bearer tokens/prompts in telemetry.')
~~~

## Delayed and truncated stream checks

~~~python
import http.client,json,os,subprocess,sys,time,urllib.request
from pathlib import Path
if len(sys.argv)>1 and sys.argv[1]=='server':
 from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
 class Handler(BaseHTTPRequestHandler):
  def log_message(self,*_):pass
  def do_POST(self):
   body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
   if self.path=='/apply-template':result={'prompt':'formatted'}
   elif self.path=='/tokenize':result={'tokens':[1,2,3]}
   else:
    self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
    self.wfile.write(b'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n');self.wfile.flush();time.sleep(2)
    self.wfile.write(b'data: {"choices":[{"delta":{"content":"river"}}]}\n\n');self.wfile.flush()
    if body['messages'][0]['content']!='truncate':self.wfile.write(b'data: {"choices":[],"usage":{"completion_tokens":1}}\n\ndata: [DONE]\n\n');self.wfile.flush()
    self.close_connection=True;return
   data=json.dumps(result).encode();self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 ThreadingHTTPServer(('127.0.0.1',18088),Handler).serve_forever();raise SystemExit
sys.path.insert(0,'/tmp/blueprint-phase8-live/serve/src');from serve.stream import chat
from dataclasses import asdict
out=Path('/home/techieemma/projects/Nicholas-Engineering-Blueprint/lessons/08-ai-infrastructure/evidence/platform-validation');tokens=json.loads(Path('/tmp/blueprint-phase8-platform/access.private.json').read_text())['tokens'];os.environ['RUNWAY_TOKEN']=tokens['acme']
def run(*args):return subprocess.check_output(list(args),stderr=subprocess.STDOUT,text=True)
run('docker','run','-d','--name','blueprint-phase8-fake-stream','--network','host','-v','/tmp/blueprint-phase8-observability-faults.py:/check.py:ro','--entrypoint','/usr/local/bin/python','runway-predictor:dev','/check.py','server')
env=dict(v.split('=',1) for v in json.loads(run('docker','inspect','blueprint-phase8-api'))[0]['Config']['Env']);env.update(INFERENCE_UPSTREAM='http://127.0.0.1:18088',LISTEN_ADDR='127.0.0.1:18181',GRPC_ADDR='127.0.0.1:18183',INFERENCE_SLOTS='1',INFERENCE_QUEUE='1')
cmd=['docker','run','-d','--name','blueprint-phase8-api-observe','--network','host']
for key in ('AUTH_MODE','AUTH_ISSUER','AUTH_AUDIENCE','LISTEN_ADDR','GRPC_ADDR','RATE_LIMIT','INFERENCE_UPSTREAM','INFERENCE_REDIS_ADDR','INFERENCE_TOKEN_BUDGET','INFERENCE_SLOTS','INFERENCE_QUEUE','OTEL_EXPORTER_OTLP_ENDPOINT'):cmd+=['-e',key+'='+env[key]]
cmd+=['blueprint-phase8-api:validation'];run(*cmd)
try:
 for _ in range(50):
  try:urllib.request.urlopen('http://127.0.0.1:18181/ready',timeout=1);break
  except OSError:time.sleep(.1)
 body=json.dumps({'messages':[{'role':'user','content':'delayed'}],'max_tokens':8,'stream':True})
 conn=http.client.HTTPConnection('127.0.0.1',18181,timeout=10);start=time.monotonic();conn.request('POST','/v1/chat/completions',body,{'Content-Type':'application/json','Authorization':'Bearer '+tokens['acme']});response=conn.getresponse()
 line=response.readline();first_byte=time.monotonic()-start;assert b'role' in line and first_byte<1,line
 remainder=response.read();assert b'[DONE]' in remainder;complete=time.monotonic()-start;assert complete>=2;conn.close()
 result=asdict(chat('http://127.0.0.1:18181','truncate',8));assert result['ttft']>=1.8 and result['error']=='incomplete or empty stream',result
 metrics=urllib.request.urlopen('http://127.0.0.1:18181/metrics').read().decode()
 assert 'inference_good_total 0' in metrics and 'inference_outcomes_total{outcome="incomplete"} 1' in metrics and 'inference_outcomes_total{outcome="complete"} 1' in metrics
 for token in tokens.values():assert token not in metrics
 (out/'observability-faults.json').write_text(json.dumps({'first_role_seconds':first_byte,'complete_seconds':complete,'truncated_stream':result,'good_total':0,'complete_count':1,'incomplete_count':1},indent=2)+'\n');(out/'observability-fault-metrics.txt').write_text(metrics)
 print('Real API: immediate role event was not a fast-content success; HTTP-200 truncated stream counted incomplete.')
finally:run('docker','rm','-f','blueprint-phase8-api-observe','blueprint-phase8-fake-stream')
~~~

## Six-fault game day

~~~python
import concurrent.futures,dataclasses,http.client,json,os,socket,struct,subprocess,sys,threading,time,urllib.request
from pathlib import Path
sys.path.insert(0,'/tmp/blueprint-phase8-live/serve/src')
from serve.stream import chat
out=Path('/home/techieemma/projects/Nicholas-Engineering-Blueprint/lessons/08-ai-infrastructure/evidence/platform-validation')
tokens=json.loads(Path('/tmp/blueprint-phase8-platform/access.private.json').read_text())['tokens'];os.environ['RUNWAY_TOKEN']=tokens['acme'];url='http://127.0.0.1:18081'
records=[];epoch=time.monotonic()
def docker(*args):return subprocess.check_output(['docker',*args],stderr=subprocess.STDOUT,text=True).strip()
def probe(max_tokens=8,prompt='Reply with river only.'):
 start=time.monotonic()-epoch;r=dataclasses.asdict(chat(url,prompt,max_tokens,timeout=35));r.pop('text');r['started_seconds']=start;return r
def get(path):return json.load(urllib.request.urlopen('http://127.0.0.1:18080'+path,timeout=2))
def ready():
 deadline=time.monotonic()+45
 while time.monotonic()<deadline:
  try:
   if get('/health')['status']=='ok':return
  except OSError:pass
  time.sleep(.1)
 raise TimeoutError('model not ready')
def recover():
 rows=[];streak=0;deadline=time.monotonic()+90
 while streak<10 and time.monotonic()<deadline:
  row=probe();rows.append(row);streak=0 if row['error'] else streak+1
 assert streak==10,rows
 return rows
def save(): (out/'game-day.json').write_text(json.dumps({'clock':'monotonic seconds from run start','recovery_contract':'10 consecutive completed nonempty streams','cases':records},indent=2)+'\n')
for rep in (1,2):
 for fault in ('model-exit','redis-unavailable','overload','client-disconnect','scraper-loss','model-oom'):
  record={'fault':fault,'repetition':rep,'injected_seconds':time.monotonic()-epoch};print('begin',fault,rep,flush=True)
  try:
   if fault=='model-exit':
    docker('kill','blueprint-phase8-llm');row=probe();record['during']=[row];assert row['error']=='status 502',row
    record['detected_seconds']=time.monotonic()-epoch;docker('start','blueprint-phase8-llm');ready()
   elif fault=='redis-unavailable':
    docker('stop','-t','1','blueprint-phase8-redis');row=probe();record['during']=[row];assert row['error']=='status 503',row
    record['detected_seconds']=time.monotonic()-epoch;docker('start','blueprint-phase8-redis')
   elif fault=='overload':
    barrier=threading.Barrier(18)
    def offered(_):barrier.wait();return probe(128,'Count from one to one thousand, one number per line.')
    with concurrent.futures.ThreadPoolExecutor(max_workers=18) as pool:rows=list(pool.map(offered,range(18)))
    record['during']=rows;assert any(r['error']=='status 503' for r in rows),rows
    record['detected_seconds']=min(r['started_seconds']+r['total'] for r in rows if r['error'])
   elif fault=='client-disconnect':
    body=json.dumps({'messages':[{'role':'user','content':'Count from one to one thousand, one number per line.'}],'stream':True,'max_tokens':512}).encode()
    s=socket.create_connection(('127.0.0.1',18081),timeout=10)
    head=('POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nAuthorization: Bearer '+tokens['acme']+'\r\nContent-Length: '+str(len(body))+'\r\n\r\n').encode();s.sendall(head+body)
    received=b''
    while b'data:' not in received:received+=s.recv(4096)
    record['processing_before_disconnect']=any(x['is_processing'] for x in get('/slots'));assert record['processing_before_disconnect']
    s.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0));s.close()
    deadline=time.monotonic()+8
    while any(x['is_processing'] for x in get('/slots')):
     assert time.monotonic()<deadline,'cancelled request leaked model capacity';time.sleep(.05)
    record['backend_idle_seconds']=time.monotonic()-epoch
   elif fault=='scraper-loss':
    docker('stop','-t','1','blueprint-phase8-prometheus')
    try:urllib.request.urlopen('http://127.0.0.1:19090/-/ready',timeout=2);raise AssertionError('scraper still up')
    except OSError:record['scraper_unavailable']=True
    row=probe();record['during']=[row];assert not row['error'],row
    docker('start','blueprint-phase8-prometheus')
   elif fault=='model-oom':
    docker('update','--memory','32m','--memory-swap','32m','blueprint-phase8-llm')
    record['memory_pressure_probe']=probe(128,'Count from one to one thousand, one number per line.')
    deadline=time.monotonic()+15
    while time.monotonic()<deadline:
     state=json.loads(docker('inspect','blueprint-phase8-llm'))[0]['State']
     if not state['Running']:break
     time.sleep(.1)
    assert state['OOMKilled'],state
    record['oom_state']={k:state[k] for k in ('OOMKilled','ExitCode','StartedAt','FinishedAt')}
    record['during']=[probe()];assert record['during'][0]['error']
    docker('update','--memory','2g','--memory-swap','2g','blueprint-phase8-llm');docker('start','blueprint-phase8-llm');ready()
   record['mitigated_seconds']=time.monotonic()-epoch
   record['recovery']=recover();record['recovered_seconds']=time.monotonic()-epoch;record['passed']=True
  except Exception as e:
   record['passed']=False;record['failure']=str(e);records.append(record);save();raise
  records.append(record);save();print('passed',fault,rep,record['recovered_seconds']-record['injected_seconds'],flush=True)
print('All game-day cases passed twice',flush=True)
~~~

## Image admission

~~~python
import subprocess,json,os,time
from pathlib import Path
r=Path('/tmp/blueprint-phase8-platform'); c='/tmp/blueprint-phase8-tools/cosign'
k=['kubectl','--kubeconfig',str(r/'kubeconfig')]
def run(args,**kw): return subprocess.run(args,check=True,text=True,capture_output=True,**kw).stdout
keydir=r/'signing';keydir.mkdir(mode=0o700,exist_ok=True)
env={**os.environ,'COSIGN_PASSWORD':''}
for name in ('trusted','wrong'):
 if not (keydir/(name+'.key')).exists():run([c,'generate-key-pair','--output-key-prefix',str(keydir/name)],env=env)
policy={'apiVersion':'policy.sigstore.dev/v1beta1','kind':'ClusterImagePolicy','metadata':{'name':'phase8-trusted-release'},'spec':{'images':[{'glob':'172.18.254.250:5000/phase8-api**'}],'authorities':[{'key':{'data':(keydir/'trusted.pub').read_text()},'signatureFormat':'legacy'}]}}
(r/'image-policy.json').write_text(json.dumps(policy))
print(run(k+['apply','-f',str(r/'image-policy.json')]))
print(run(k+['-n','cosign-system','patch','cm','config-policy-controller','--type','merge','-p',json.dumps({'data':{'no-match-policy':'deny'}})]))
print(run(k+['label','namespace','phase8','policy.sigstore.dev/include=true','--overwrite']))
digest=run(['docker','image','inspect','localhost:15001/phase8-api-admission2:validation','--format','{{index .RepoDigests 0}}']).strip().split('@')[1]
image='172.18.254.250:5000/phase8-api-admission2@'+digest
pod={'apiVersion':'v1','kind':'Pod','metadata':{'name':'admission-probe','namespace':'phase8'},'spec':{'restartPolicy':'Never','containers':[{'name':'api','image':image}]}}
records=[]
def probe(case,expected):
 p=subprocess.run(k+['create','--dry-run=server','-f','-'],input=json.dumps(pod),capture_output=True,text=True)
 records.append({'case':case,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 assert (p.returncode==0)==expected,records[-1]
probe('unsigned',False)
for name in ('wrong','trusted'):
 print(run([c,'sign','--yes','--key',str(keydir/(name+'.key')),'--use-signing-config=false','--tlog-upload=false','--new-bundle-format=false','--registry-referrers-mode','legacy','--registry-cacert',str(r/'registry-certs/tls.crt'),image],env=env))
 probe(name+'-signature',name=='trusted')
(r/'admission-checks.json').write_text(json.dumps({'image':image,'cases':records},indent=2)+'\n')
print(json.dumps(records,indent=2))
~~~

## Signed model deployment and startup binding

~~~python
import hashlib,json,os,shutil,subprocess,time,urllib.request
from pathlib import Path
r=Path('/tmp/blueprint-phase8-platform');out=Path('/home/techieemma/projects/Nicholas-Engineering-Blueprint/lessons/08-ai-infrastructure/evidence/platform-validation');k=['kubectl','--kubeconfig',str(r/'kubeconfig')]
def run(args,**kw):return subprocess.run(args,check=True,capture_output=True,text=True,**kw).stdout
def apply(obj):return run(k+['apply','-f','-'],input=json.dumps(obj))
digest=run(['docker','image','inspect','localhost:15001/phase8-model:validation','--format','{{index .RepoDigests 0}}']).strip().split('@')[1];image='172.18.254.250:5000/phase8-model@'+digest
run(['/tmp/blueprint-phase8-tools/cosign','sign','--yes','--key',str(r/'signing/trusted.key'),'--use-signing-config=false','--tlog-upload=false','--new-bundle-format=false','--registry-referrers-mode','legacy','--registry-cacert',str(r/'registry-certs/tls.crt'),image],env={**os.environ,'COSIGN_PASSWORD':''})
policy=json.loads((r/'image-policy.json').read_text());policy['metadata']['name']='phase8-model-release';policy['spec']['images']=[{'glob':'172.18.254.250:5000/phase8-model**'}];apply(policy)
ns={'apiVersion':'v1','kind':'Namespace','metadata':{'name':'phase8-model','labels':{'policy.sigstore.dev/include':'true','pod-security.kubernetes.io/enforce':'restricted'}}};apply(ns)
weights=r/'k8s-weights';weights.mkdir(exist_ok=True)
for name in ('manifest.json','manifest.sigstore.json','weights.spdx.json','provenance.json'):shutil.copy('/tmp/blueprint-phase8-release/weights/'+name,weights/name);(weights/name).chmod(0o644)
shutil.copy('/home/techieemma/blueprint-scratch/models/qwen2.5-0.5b-instruct-q4_k_m.gguf',weights/'model.gguf');(weights/'model.gguf').chmod(0o644)
run(['docker','exec','blueprint-phase8-control-plane','mkdir','-p','/var/phase8-weights']);run(['docker','cp',str(weights)+'/.','blueprint-phase8-control-plane:/var/phase8-weights/'])
apply({'apiVersion':'v1','kind':'PersistentVolume','metadata':{'name':'phase8-weights'},'spec':{'capacity':{'storage':'1Gi'},'accessModes':['ReadOnlyMany'],'storageClassName':'','persistentVolumeReclaimPolicy':'Retain','hostPath':{'path':'/var/phase8-weights','type':'Directory'},'claimRef':{'namespace':'phase8-model','name':'phase8-weights'}}})
apply({'apiVersion':'v1','kind':'PersistentVolumeClaim','metadata':{'name':'phase8-weights','namespace':'phase8-model'},'spec':{'accessModes':['ReadOnlyMany'],'storageClassName':'','volumeName':'phase8-weights','resources':{'requests':{'storage':'1Gi'}}}})
# A native CEL policy binds the approved image and prevents bypassing startup verification.
exprs=["size(object.spec.containers) == 1 && object.spec.containers.all(c, c.image == '"+image+"' && (!has(c.command) || size(c.command)==0) && (!has(c.args) || size(c.args)==0) && (!has(c.env) || size(c.env)==0) && (!has(c.envFrom) || size(c.envFrom)==0))","(!has(object.spec.initContainers) || size(object.spec.initContainers)==0) && (!has(object.spec.ephemeralContainers) || size(object.spec.ephemeralContainers)==0)","object.spec.containers.all(c, has(c.volumeMounts) && c.volumeMounts.all(v, v.mountPath in ['/models','/verified','/tmp'] && !has(v.subPath) && !has(v.subPathExpr)))","has(object.spec.volumes) && object.spec.volumes.all(v, (v.name == 'weights' && has(v.persistentVolumeClaim) && v.persistentVolumeClaim.claimName == 'phase8-weights') || (v.name in ['verified','temp'] && has(v.emptyDir)))"]
apply({'apiVersion':'admissionregistration.k8s.io/v1','kind':'ValidatingAdmissionPolicy','metadata':{'name':'phase8-model-startup'},'spec':{'failurePolicy':'Fail','matchConstraints':{'resourceRules':[{'apiGroups':[''],'apiVersions':['v1'],'operations':['CREATE','UPDATE'],'resources':['pods','pods/ephemeralcontainers']}]},'validations':[{'expression':e,'message':'Use the approved release and its fixed startup verifier; no command/env/mount overrides.'} for e in exprs]}})
apply({'apiVersion':'admissionregistration.k8s.io/v1','kind':'ValidatingAdmissionPolicyBinding','metadata':{'name':'phase8-model-startup'},'spec':{'policyName':'phase8-model-startup','validationActions':['Deny'],'matchResources':{'namespaceSelector':{'matchLabels':{'kubernetes.io/metadata.name':'phase8-model'}}}}})
spec={'automountServiceAccountToken':False,'securityContext':{'runAsNonRoot':True,'runAsUser':1000,'runAsGroup':1000,'fsGroup':1000,'seccompProfile':{'type':'RuntimeDefault'}},'containers':[{'name':'server','image':image,'imagePullPolicy':'IfNotPresent','securityContext':{'allowPrivilegeEscalation':False,'readOnlyRootFilesystem':True,'capabilities':{'drop':['ALL']}},'ports':[{'name':'http','containerPort':8080}],'resources':{'requests':{'cpu':'1','memory':'768Mi'},'limits':{'cpu':'2','memory':'1536Mi'}},'startupProbe':{'httpGet':{'path':'/health','port':'http'},'periodSeconds':1,'failureThreshold':120},'readinessProbe':{'httpGet':{'path':'/health','port':'http'},'periodSeconds':1},'volumeMounts':[{'name':'weights','mountPath':'/models','readOnly':True},{'name':'verified','mountPath':'/verified'},{'name':'temp','mountPath':'/tmp'}]}],'volumes':[{'name':'weights','persistentVolumeClaim':{'claimName':'phase8-weights','readOnly':True}},{'name':'verified','emptyDir':{'sizeLimit':'1Gi'}},{'name':'temp','emptyDir':{}}]}
deployment={'apiVersion':'apps/v1','kind':'Deployment','metadata':{'name':'llm','namespace':'phase8-model'},'spec':{'replicas':1,'strategy':{'type':'Recreate'},'selector':{'matchLabels':{'app':'llm'}},'template':{'metadata':{'labels':{'app':'llm'}},'spec':spec}}}
(r/'model-deployment.json').write_text(json.dumps(deployment,indent=2));apply(deployment)
apply({'apiVersion':'v1','kind':'Service','metadata':{'name':'llm','namespace':'phase8-model'},'spec':{'selector':{'app':'llm'},'ports':[{'port':8080,'targetPort':'http'}]}})
records={'image':image,'manifest_sha256':Path('/tmp/blueprint-phase8-model-image/expected-manifest.txt').read_text().strip(),'checks':[]}
def pods():return json.loads(run(k+['-n','phase8-model','get','pods','-l','app=llm','-o','json']))['items']
def wait_ready(label):
 start=time.monotonic();samples=[];deadline=start+150
 while time.monotonic()<deadline:
  items=pods()
  if items:
   p=items[-1];ready=any(c['type']=='Ready' and c['status']=='True' for c in p.get('status',{}).get('conditions',[]));samples.append({'elapsed_seconds':time.monotonic()-start,'phase':p.get('status',{}).get('phase'),'ready':ready})
   if ready:
    records['checks'].append({'case':label,'wait_seconds':time.monotonic()-start,'pod':p,'samples':samples});return p
  time.sleep(.25)
 raise TimeoutError(json.dumps(items))
p=wait_ready('cold-create');print('cold ready',p['metadata']['name'],flush=True)
run(k+['-n','phase8-model','delete','pod',p['metadata']['name'],'--wait=true','--timeout=30s'])
p=wait_ready('warm-replacement');print('warm ready',p['metadata']['name'],flush=True)
# Dry-run negative cases are enforced by the same server admission path.
for label,mutation in [('entrypoint-override',lambda s:s['containers'][0].update(command=['/app/llama-server'])),('environment-override',lambda s:s['containers'][0].update(env=[{'name':'LLAMA_ARG_MODEL','value':'/tmp/other'}])),('old-release-digest',lambda s:s['containers'][0].update(image='172.18.254.250:5000/phase8-model@sha256:'+'0'*64))]:
 s=json.loads(json.dumps(spec));mutation(s);pod={'apiVersion':'v1','kind':'Pod','metadata':{'name':'override-probe','namespace':'phase8-model'},'spec':s};result=subprocess.run(k+['create','--dry-run=server','-f','-'],input=json.dumps(pod),capture_output=True,text=True);assert result.returncode!=0,(label,result.stdout);records['checks'].append({'case':label,'exit_code':result.returncode,'stderr':result.stderr})
records['logs']=run(k+['-n','phase8-model','logs',p['metadata']['name']]);(out/'kubernetes-checks.json').write_text(json.dumps(records,indent=2)+'\n');print('Kubernetes readiness and entrypoint binding checks passed',flush=True)
~~~

## Weight, trust and webhook failures

~~~python
import copy,json,os,subprocess,time,urllib.request
from pathlib import Path
r=Path('/tmp/blueprint-phase8-platform');out=Path('/home/techieemma/projects/Nicholas-Engineering-Blueprint/lessons/08-ai-infrastructure/evidence/platform-validation');k=['kubectl','--kubeconfig',str(r/'kubeconfig')]
def run(args,**kw):return subprocess.run(args,check=True,capture_output=True,text=True,**kw).stdout
def kube(*args):return run(k+list(args))
def pods():return json.loads(kube('-n','phase8-model','get','pods','-l','app=llm','-o','json'))['items']
def replace():
 for p in pods():kube('-n','phase8-model','delete','pod',p['metadata']['name'],'--wait=true','--timeout=30s')
def wait_ready():
 deadline=time.monotonic()+150
 while time.monotonic()<deadline:
  for p in pods():
   if any(c['type']=='Ready' and c['status']=='True' for c in p.get('status',{}).get('conditions',[])):return p
  time.sleep(.25)
 raise TimeoutError('model readiness did not recover')
def refused():
 deadline=time.monotonic()+60
 while time.monotonic()<deadline:
  for p in pods():
   statuses=p.get('status',{}).get('containerStatuses',[])
   for s in statuses:
    term=s.get('state',{}).get('terminated') or s.get('lastState',{}).get('terminated')
    if term and term['exitCode']!=0:
     assert not s['ready'];logs=kube('-n','phase8-model','logs',p['metadata']['name'])
     if 'model startup refused' not in logs and s.get('restartCount',0)>0:
      previous=subprocess.run(k+['-n','phase8-model','logs',p['metadata']['name'],'--previous'],capture_output=True,text=True);logs=previous.stdout
     if 'model startup refused' not in logs:continue
     return {'exit_code':term['exitCode'],'ready':s['ready'],'logs':logs}
  time.sleep(.25)
 raise TimeoutError('tampered weights were not refused')
records=[]
for rep in (1,2):
 start=time.monotonic();subprocess.run(['docker','exec','-i','blueprint-phase8-control-plane','dd','of=/var/phase8-weights/model.gguf','bs=1','count=1','conv=notrunc'],input=b'F',check=True,capture_output=True)
 try:replace();result=refused()
 finally:subprocess.run(['docker','exec','-i','blueprint-phase8-control-plane','dd','of=/var/phase8-weights/model.gguf','bs=1','count=1','conv=notrunc'],input=b'G',check=True,capture_output=True)
 replace();p=wait_ready();records.append({'case':'corrupt-model-startup','repetition':rep,'refusal':result,'rollback_ready':True,'elapsed_seconds':time.monotonic()-start})
 print('corrupt model refused and restored',rep,flush=True)
run(['docker','exec','blueprint-phase8-control-plane','mv','/var/phase8-weights/manifest.sigstore.json','/var/phase8-weights/manifest.hidden'])
try:replace();result=refused()
finally:run(['docker','exec','blueprint-phase8-control-plane','mv','/var/phase8-weights/manifest.hidden','/var/phase8-weights/manifest.sigstore.json'])
replace();wait_ready();records.append({'case':'missing-bundle','refusal':result,'rollback_ready':True})
# The live controller must fail closed when the trust authority is removed.
deployment=json.loads((r/'model-deployment.json').read_text());pod={'apiVersion':'v1','kind':'Pod','metadata':{'name':'trust-probe','namespace':'phase8-model'},'spec':deployment['spec']['template']['spec']}
def probe():return subprocess.run(k+['create','--dry-run=server','-f','-'],input=json.dumps(pod),capture_output=True,text=True)
policy=json.loads(kube('get','clusterimagepolicy','phase8-model-release','-o','json'));original=copy.deepcopy(policy['spec']);changed=copy.deepcopy(original);changed['authorities'][0]['key']['data']=(r/'signing/wrong.pub').read_text()
kube('patch','clusterimagepolicy','phase8-model-release','--type','merge','-p',json.dumps({'spec':changed}));time.sleep(1)
try:
 result=probe();assert result.returncode!=0;records.append({'case':'revoked-key-denied','exit_code':result.returncode,'stderr':result.stderr})
finally:kube('patch','clusterimagepolicy','phase8-model-release','--type','merge','-p',json.dumps({'spec':original}))
time.sleep(1);assert probe().returncode==0
kube('-n','cosign-system','scale','deployment','phase8-policy-policy-controller-webhook','--replicas=0')
controller=json.loads(kube('-n','cosign-system','get','pods','-o','json'))['items']
for item in controller:
 if item['metadata']['name'].startswith('phase8-policy-policy-controller-webhook-'):
  kube('-n','cosign-system','delete','pod',item['metadata']['name'],'--grace-period=0','--force')
time.sleep(2)
try:
 deadline=time.monotonic()+25
 while True:
  result=probe()
  if result.returncode!=0:break
  assert time.monotonic()<deadline,'webhook kept accepting while unavailable'
  time.sleep(.5)
 assert 'no endpoints available' in result.stderr or 'failed calling webhook' in result.stderr,result.stderr
 records.append({'case':'webhook-outage-fail-closed','exit_code':result.returncode,'stderr':result.stderr})
finally:
 kube('-n','cosign-system','scale','deployment','phase8-policy-policy-controller-webhook','--replicas=1');kube('-n','cosign-system','rollout','status','deployment/phase8-policy-policy-controller-webhook','--timeout=90s')
assert probe().returncode==0
(out/'kubernetes-faults.json').write_text(json.dumps(records,indent=2)+'\n');print('Kubernetes weight refusal, trust revocation and webhook outage checks passed',flush=True)
~~~

## Metrics/API bridge proxy

~~~go
package main
import("net/http";"net/http/httputil";"net/url";"log")
func main(){
 api,_:=url.Parse("http://127.0.0.1:18081");go func(){log.Fatal(http.ListenAndServe("172.18.0.1:18089",httputil.NewSingleHostReverseProxy(api)))}()
 u,_:=url.Parse("http://127.0.0.1:19090");p:=httputil.NewSingleHostReverseProxy(u);log.Fatal(http.ListenAndServe("172.18.0.1:19091",http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){if r.Method!="GET" || (r.URL.Path!="/api/v1/query" && r.URL.Path!="/api/v1/query_range" && r.URL.Path!="/api/v1/series"){http.Error(w,"read-only metric queries",403);return};p.ServeHTTP(w,r)})))}
~~~

## Real-metric HPA

~~~python
import concurrent.futures,dataclasses,json,os,subprocess,sys,time,urllib.request
from pathlib import Path
sys.path.insert(0,'/tmp/blueprint-phase8-live/serve/src');from serve.stream import chat
r=Path('/tmp/blueprint-phase8-platform');out=Path('/home/techieemma/projects/Nicholas-Engineering-Blueprint/lessons/08-ai-infrastructure/evidence/platform-validation');k=['kubectl','--kubeconfig',str(r/'kubeconfig')]
def run(args,**kw):return subprocess.run(args,check=True,capture_output=True,text=True,**kw).stdout
def kube(*args):return run(k+list(args))
def apply(obj):return run(k+['apply','-f','-'],input=json.dumps(obj))
deadline=time.monotonic()+150
while not (out/'kubernetes-faults.json').exists():
 assert time.monotonic()<deadline,'finish the weight and webhook fault checks before HPA';time.sleep(.5)
kube('-n','phase8-model','patch','service','llm','--type','merge','-p',json.dumps({'spec':{'type':'NodePort','ports':[{'port':8080,'targetPort':'http','nodePort':30080}]}}))
node=json.loads(run(['docker','inspect','blueprint-phase8-control-plane']))[0]['NetworkSettings']['Networks']['kind']['IPAddress']
upstream='http://'+node+':30080';assert json.load(urllib.request.urlopen(upstream+'/health',timeout=3))['status']=='ok'
start_script=Path('/tmp/blueprint-phase8-platform/start-api.py').read_text().replace("'http://127.0.0.1:18080'",repr(upstream)).replace("'INFERENCE_SLOTS':'1'","'INFERENCE_SLOTS':'3'")
(r/'start-kube-api.py').write_text(start_script);run(['docker','rm','-f','blueprint-phase8-api','blueprint-phase8-idp']);print(run(['python3',str(r/'start-kube-api.py')]),flush=True)
token=json.loads((r/'access.private.json').read_text())['tokens']['acme'];os.environ['RUNWAY_TOKEN']=token
# The Service names the external gateway represented by this scrape's service label.
apply({'apiVersion':'v1','kind':'Service','metadata':{'name':'api','namespace':'phase8-model'},'spec':{'ports':[{'name':'http','port':18081,'targetPort':18089}]}})
apply({'apiVersion':'discovery.k8s.io/v1','kind':'EndpointSlice','metadata':{'name':'phase8-external-api','namespace':'phase8-model','labels':{'kubernetes.io/service-name':'api'}},'addressType':'IPv4','ports':[{'name':'http','protocol':'TCP','port':18089}],'endpoints':[{'addresses':['172.18.0.1'],'conditions':{'ready':True}}]})
metric_path='/apis/custom.metrics.k8s.io/v1beta1/namespaces/phase8-model/services/api/inference_waiting'
deadline=time.monotonic()+40
while True:
 p=subprocess.run(k+['get','--raw',metric_path],capture_output=True,text=True)
 if p.returncode==0:metric=json.loads(p.stdout);break
 assert time.monotonic()<deadline,p.stderr;time.sleep(1)
assert metric['items'][0]['metricName']=='inference_waiting',metric
hpa={'apiVersion':'autoscaling/v2','kind':'HorizontalPodAutoscaler','metadata':{'name':'llm','namespace':'phase8-model'},'spec':{'scaleTargetRef':{'apiVersion':'apps/v1','kind':'Deployment','name':'llm'},'minReplicas':1,'maxReplicas':2,'behavior':{'scaleDown':{'stabilizationWindowSeconds':300}},'metrics':[{'type':'Object','object':{'describedObject':{'apiVersion':'v1','kind':'Service','name':'api'},'metric':{'name':'inference_waiting'},'target':{'type':'AverageValue','averageValue':'2'}}}]}}
apply(hpa);(r/'hpa.json').write_text(json.dumps(hpa,indent=2))
start=time.monotonic();stop=start+65;rows=[];snapshots=[]
def load(worker):
 results=[]
 while time.monotonic()<stop:
  at=time.monotonic()-start;result=dataclasses.asdict(chat('http://127.0.0.1:18081','Count from one to one thousand, one number per line.',512,timeout=35));result.pop('text');result.update(worker=worker,started_seconds=at);results.append(result)
 return results
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
 futures=[pool.submit(load,i) for i in range(8)]
 while time.monotonic()<stop:
  snapshot={'elapsed_seconds':time.monotonic()-start,'hpa':json.loads(kube('-n','phase8-model','get','hpa','llm','-o','json')),'deployment':json.loads(kube('-n','phase8-model','get','deployment','llm','-o','json')),'metric':json.loads(kube('get','--raw',metric_path))};snapshots.append(snapshot);time.sleep(2)
 for f in futures:rows.extend(f.result())
scaled=any(s['deployment']['spec']['replicas']==2 for s in snapshots);assert scaled,'HPA never scaled on the real waiting metric'
kube('-n','phase8-model','rollout','status','deployment/llm','--timeout=120s')
pods=json.loads(kube('-n','phase8-model','get','pods','-l','app=llm','-o','json'))['items'];assert len(pods)==2
logs={p['metadata']['name']:kube('-n','phase8-model','logs',p['metadata']['name']) for p in pods}
# This pinned server logs generation slot launches/timings, not HTTP access lines.
(out/'hpa-load-attempt.json').write_text(json.dumps({'samples':snapshots,'arrivals':rows,'backend_logs':logs},indent=2)+'\n')
assert all('processing task, is_child' in v and 'eval time =' in v for v in logs.values()),'requests did not reach both backend replicas'
recovery=[]
for _ in range(10):
 result=dataclasses.asdict(chat('http://127.0.0.1:18081','Reply with river only.',8));result.pop('text');assert not result['error'],result;recovery.append(result)
(out/'hpa-checks.json').write_text(json.dumps({'upstream':upstream,'gateway_active_capacity':3,'gateway_queue_capacity':8,'metric_before':metric,'samples':snapshots,'arrivals':rows,'recovery':recovery,'both_replicas_received_generation':True,'backend_logs':logs},indent=2)+'\n')
print('Real custom metric drove 1->2 replicas; both received generation requests; ten requests recovered.',flush=True)
~~~

## Cluster API route and image SBOM capture

~~~python
import gzip,hashlib,json,subprocess,time
from pathlib import Path
r=Path('/tmp/blueprint-phase8-platform');out=Path('/home/techieemma/projects/Nicholas-Engineering-Blueprint/lessons/08-ai-infrastructure/evidence/platform-validation');k=['kubectl','--kubeconfig',str(r/'kubeconfig')]
pods=json.loads(subprocess.check_output(k+['-n','phase8-model','get','pods','-l','app=llm','-o','json'],text=True))['items'];pod=next(p['metadata']['name'] for p in pods if not p['metadata'].get('deletionTimestamp'))
token=json.loads((r/'access.private.json').read_text())['tokens']['acme'];body=json.dumps({'messages':[{'role':'user','content':'Reply with river only.'}],'max_tokens':8,'stream':True})
config='url = "http://api.phase8-model.svc.cluster.local:18081/v1/chat/completions"\nrequest = "POST"\nheader = "Content-Type: application/json"\nheader = "Authorization: Bearer '+token+'"\ndata = '+json.dumps(body)+'\nsilent\nshow-error\nfail\n'
p=subprocess.run(k+['-n','phase8-model','exec','-i',pod,'--','curl','--config','-'],input=config,text=True,capture_output=True,timeout=35)
assert p.returncode==0 and '[DONE]' in p.stdout,(p.returncode,p.stderr,p.stdout)
(out/'cluster-api-route.json').write_text(json.dumps({'path':'pod -> gateway Service/EndpointSlice -> lab proxy -> JWT API -> model NodePort/Service -> verified model pod','generation_completed':True,'exit_code':p.returncode,'response_contains_done':True,'tenant':'synthetic verified claim; no bearer token retained'},indent=2)+'\n')
source=r/'model-image.spdx.json';data=source.read_bytes();sbom=json.loads(data);assert sbom['packages']
with gzip.open(out/'model-image.spdx.json.gz','wb') as f:f.write(data)
(out/'model-sbom-summary.json').write_text(json.dumps({'sha256':hashlib.sha256(data).hexdigest(),'packages':len(sbom['packages']),'spdx_version':sbom['spdxVersion'],'compressed_evidence':'model-image.spdx.json.gz','vulnerability_scan':'not measured; SBOM inventory does not establish absence of vulnerabilities'},indent=2)+'\n')
print('Authenticated API route from inside the cluster completed; exact derived-image SBOM retained.')
~~~

## Startup allowance and replacement

~~~python
import concurrent.futures,dataclasses,json,os,subprocess,sys,time,datetime
from pathlib import Path
sys.path.insert(0,'/tmp/blueprint-phase8-live/serve/src');from serve.stream import chat
r=Path('/tmp/blueprint-phase8-platform');out=Path('/home/techieemma/projects/Nicholas-Engineering-Blueprint/lessons/08-ai-infrastructure/evidence/platform-validation');k=['kubectl','--kubeconfig',str(r/'kubeconfig')];os.environ['RUNWAY_TOKEN']=json.loads((r/'access.private.json').read_text())['tokens']['acme']
def kube(*args):return subprocess.check_output(k+list(args),text=True,stderr=subprocess.STDOUT)
def pods():return [p for p in json.loads(kube('-n','phase8-model','get','pods','-l','app=llm','-o','json'))['items'] if not p['metadata'].get('deletionTimestamp')]
def probe():
 start=time.monotonic();row=dataclasses.asdict(chat('http://127.0.0.1:18081','Reply with river only.',8,timeout=35));row.pop('text');return {**row,'started_monotonic':start,'finished_monotonic':time.monotonic()}
def ready():
 deadline=time.monotonic()+90
 while time.monotonic()<deadline:
  ps=pods()
  if ps and all(any(c['type']=='Ready' and c['status']=='True' for c in p.get('status',{}).get('conditions',[])) for p in ps):return ps
  time.sleep(.25)
 raise TimeoutError('startup did not recover')
# Hold at one replica for a clearly scoped Recreate outage measurement.
kube('-n','phase8-model','delete','hpa','llm','--ignore-not-found=true');kube('-n','phase8-model','scale','deployment','llm','--replicas=1');ready()
records=[]
with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
 start=time.monotonic();old={p['metadata']['name'] for p in pods()};futures=[]
 for p in pods():kube('-n','phase8-model','delete','pod',p['metadata']['name'],'--wait=false','--ignore-not-found=true')
 for i in range(16):
  futures.append(pool.submit(probe));time.sleep(1)
 rows=[f.result() for f in futures];ps=ready();new=[p for p in ps if p['metadata']['name'] not in old];assert new
 success=next(x for x in sorted(rows,key=lambda x:x['finished_monotonic']) if not x['error'])
 records.append({'case':'warm-replacement-through-actual-api','incident_monotonic':start,'first_completed_after_delete_seconds':success['finished_monotonic']-start,'arrivals':rows,'pods':new})
# An allowance shorter than the real load time produces a restart, not readiness.
patch={'spec':{'template':{'spec':{'containers':[{'name':'server','startupProbe':{'failureThreshold':1,'periodSeconds':1}}]}}}}
kube('-n','phase8-model','patch','deployment','llm','--type','strategic','-p',json.dumps(patch))
try:
 deadline=time.monotonic()+50
 while True:
  ps=pods();failed=[p for p in ps if any(s.get('restartCount',0)>0 for s in p.get('status',{}).get('containerStatuses',[]))]
  if failed:break
  assert time.monotonic()<deadline,'short startup probe did not cause an observed restart';time.sleep(.25)
 records.append({'case':'startup-budget-too-short','pods':failed,'events':kube('-n','phase8-model','get','events','--field-selector','reason=Unhealthy','-o','json')})
finally:
 patch['spec']['template']['spec']['containers'][0]['startupProbe']['failureThreshold']=120;kube('-n','phase8-model','patch','deployment','llm','--type','strategic','-p',json.dumps(patch))
ready();recovery=[probe() for _ in range(10)];assert all(not x['error'] for x in recovery);records.append({'case':'restored-startup-budget','recovery':recovery})
(out/'startup-checks.json').write_text(json.dumps(records,indent=2)+'\n');print('Replacement first completion, insufficient startup allowance/restart, and restored ten-request contract captured.',flush=True)
~~~

## Network training worker

~~~python
import os,json,time,datetime
from pathlib import Path
import torch
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel as DDP
rank=int(os.environ['RANK']);case=os.environ['CASE'];mode=os.environ['MODE'];resume=os.environ.get('RESUME')=='1'
root=Path('/results')/case;root.mkdir(exist_ok=True)
torch.set_num_threads(1)
torch.manual_seed(41); model=torch.nn.Linear(128,16)
opt=torch.optim.SGD(model.parameters(),lr=.01,momentum=.9)
torch.manual_seed(7); x=torch.randn(64,128); y=torch.randn(64,16)
reference=torch.nn.Linear(128,16);reference.load_state_dict(model.state_dict());serial=torch.optim.SGD(reference.parameters(),lr=.01,momentum=.9)
for step in range(6):
 serial.zero_grad();(reference(x)-y).square().mean().backward();serial.step()
start=0
if resume:
 state=torch.load(root/'checkpoint.pt',weights_only=True)
 model.load_state_dict(state['model']);opt.load_state_dict(state['optimizer']);start=state['step'];torch.set_rng_state(state['rng'])
dist.init_process_group('gloo',timeout=datetime.timedelta(seconds=8));model=DDP(model)
t0=time.monotonic()
for step in range(start,6):
 opt.zero_grad(); loss=(model(x.chunk(2)[rank])-y.chunk(2)[rank]).square().mean();loss.backward();opt.step()
 if step==2 and not resume:
  if rank==0:
   tmp=root/'checkpoint.tmp';torch.save({'model':model.module.state_dict(),'optimizer':opt.state_dict(),'step':3,'rng':torch.get_rng_state(),'dataset_seed':7},tmp);os.replace(tmp,root/'checkpoint.pt')
  dist.barrier()
  if mode=='worker-exit' and rank==1:os._exit(17)
  if mode=='partition':
   (root/f'rank{rank}.ready').write_text('ready')
   deadline=time.monotonic()+30
   while not (root/'cut.flag').exists():
    if time.monotonic()>deadline:raise TimeoutError('fault controller absent')
    time.sleep(.05)
torch.testing.assert_close(model.module.weight,reference.weight,rtol=1e-5,atol=1e-6)
torch.testing.assert_close(model.module.bias,reference.bias,rtol=1e-5,atol=1e-6)
(root/f'rank{rank}-'+Path('x')) if False else None
result={'rank':rank,'mode':mode,'resumed':resume,'start_step':start,'end_step':6,'serial_parity':True,'train_seconds':time.monotonic()-t0}
(root/f'rank{rank}-{"resumed" if resume else "initial"}.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result),flush=True);dist.destroy_process_group()
~~~

## Network controller

~~~python
import os,json,subprocess,time
from pathlib import Path
r=Path('/tmp/blueprint-phase8-network');r.mkdir(exist_ok=True);r.chmod(0o777)
network='blueprint-phase8-training';names=['blueprint-phase8-rank0','blueprint-phase8-rank1']
def run(args,check=True,**kw):return subprocess.run(args,text=True,capture_output=True,check=check,**kw)
assert run(['docker','network','inspect',network],check=False).returncode!=0,'owned network already exists; inspect before reuse'
run(['docker','network','create','--subnet','172.30.88.0/24',network])
for rank,name in enumerate(names):
 run(['docker','run','-d','--name',name,'--network',network,'--ip',f'172.30.88.{10+rank}','--memory','1g','--cpus','1','-v','/tmp/blueprint-phase8-live/serve/.venv/lib/python3.12/site-packages:/opt/deps:ro','-v','/tmp/blueprint-phase8-network-worker.py:/worker.py:ro','-v',str(r)+':/results','-e','PYTHONPATH=/opt/deps','-e','GLOO_SOCKET_IFNAME=eth0','--entrypoint','/bin/sleep','runway-predictor:dev','infinity'])
def tc(rank,command,check=True):
 return run(['docker','run','--rm','--network','container:'+names[rank],'--cap-add','NET_ADMIN','--entrypoint','tc','nettools']+command,check=check)
def qdisc(args):
 return [tc(rank,['qdisc']+args).stdout for rank in (0,1)]
def start(case,mode,resume=False):
 ps=[]
 for rank,name in enumerate(names):
  log=(r/case/f'rank{rank}-{"resumed" if resume else "initial"}.log').open('w')
  cmd=['docker','exec','-e',f'RANK={rank}','-e','WORLD_SIZE=2','-e','MASTER_ADDR=172.30.88.10','-e','MASTER_PORT=29500','-e',f'CASE={case}','-e',f'MODE={mode}','-e',f'RESUME={int(resume)}',name,'/usr/local/bin/python','/worker.py']
  ps.append((subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT),log))
 return ps
def finish(ps):
 codes=[]
 for p,log in ps:
  try: codes.append(p.wait(timeout=70))
  except subprocess.TimeoutExpired:p.kill();codes.append(p.wait());raise
  finally:log.close()
 return codes
records=[]
for mode in ('baseline','shaped','worker-exit','partition'):
 case=mode;d=r/case;d.mkdir(exist_ok=True);d.chmod(0o777)
 for rank in (0,1):tc(rank,['qdisc','del','dev','eth0','root'],check=False)
 if mode=='shaped':qdisc(['add','dev','eth0','root','netem','delay','20ms','rate','100mbit'])
 started=time.monotonic(); ps=start(case,mode)
 if mode=='partition':
  deadline=time.monotonic()+50
  while not all((d/f'rank{rank}.ready').exists() for rank in (0,1)):
   assert time.monotonic()<deadline,'ranks did not reach checkpoint'
   time.sleep(.1)
  qdisc(['add','dev','eth0','root','netem','loss','100%'])
  (d/'cut.flag').write_text('cut')
 codes=finish(ps);stats=qdisc(['show','dev','eth0'])
 detailed=[tc(rank,['-s','qdisc','show','dev','eth0']).stdout for rank in (0,1)]
 record={'case':case,'initial_exit_codes':codes,'elapsed_seconds':time.monotonic()-started,'qdisc':stats,'qdisc_stats':detailed}
 if mode in ('worker-exit','partition'):
  assert all(code!=0 for code in codes),record
  for rank in (0,1):tc(rank,['qdisc','del','dev','eth0','root'],check=False)
  codes=finish(start(case,mode,True));assert codes==[0,0],codes
  record['resumed_exit_codes']=codes
 else:assert codes==[0,0],record
 record['results']=[json.loads(p.read_text()) for p in d.glob('*.json')]
 records.append(record);print(json.dumps(record),flush=True)
Path('/home/techieemma/projects/Nicholas-Engineering-Blueprint/lessons/08-ai-infrastructure/evidence/platform-validation/network-checks.json').write_text(json.dumps(records,indent=2)+'\n')
~~~

## Ray retry/actor/Train/Serve

~~~python
import json,os,time,tempfile
from pathlib import Path
import ray
from ray import serve
from ray.train import RunConfig,ScalingConfig
from ray.train.torch import TorchTrainer
from serve.raylab import Ledger
from serve.raytrain import loop
from serve.rayserve import app
out=Path('/home/techieemma/projects/Nicholas-Engineering-Blueprint/lessons/08-ai-infrastructure/evidence/platform-validation')
ray.init(num_cpus=4,include_dashboard=False)
records={}
try:
    ledger=Ledger.remote(); assert ray.get(ledger.commit.remote('a',7))==7
    assert ray.get(ledger.commit.remote('a',7))==7
    ray.kill(ledger)
    try: ray.get(ledger.commit.remote('a',7)); raise AssertionError('dead actor answered')
    except ray.exceptions.RayActorError: pass
    replacement=Ledger.remote(); assert ray.get(replacement.commit.remote('a',7))==7
    records['actor_loss']={'dead_actor_error':True,'replacement_loses_dedup_history':True,'durable_exactly_once':False}
    ray.kill(replacement)
    marker='/tmp/blueprint-phase8-ray-retry.marker'
    Path(marker).unlink(missing_ok=True)
    @ray.remote(max_retries=1)
    def retry():
        try: fd=os.open(marker,os.O_CREAT|os.O_EXCL|os.O_WRONLY)
        except FileExistsError: return 'retried_after_worker_loss'
        os.close(fd); os._exit(17)
    assert ray.get(retry.remote())=='retried_after_worker_loss'
    records['task_retry_after_worker_exit']=True
    result=TorchTrainer(loop,train_loop_config={'steps':4},scaling_config=ScalingConfig(num_workers=2,use_gpu=False),run_config=RunConfig(storage_path='/tmp/blueprint-phase8-ray-results',name='serial-parity')).fit()
    assert result.metrics['serial_parity']
    records['train']={k:result.metrics[k] for k in ('serial_parity','loss')}
    serve.start(http_options={'host':'127.0.0.1','port':18084})
    handle=serve.run(app)
    import urllib.request
    replies=[json.load(urllib.request.urlopen('http://127.0.0.1:18084/',timeout=20)) for _ in range(5)]
    assert all(x['ready'] and x['parameters']>0 for x in replies)
    records['serve']={'requests':len(replies),'response':replies[0]}
    records['versions']={'ray':ray.__version__}
    (out/'ray-checks.json').write_text(json.dumps(records,indent=2)+'\n')
    print(json.dumps(records,indent=2))
finally:
    serve.shutdown();ray.shutdown()
~~~
