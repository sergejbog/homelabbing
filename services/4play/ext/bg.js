
const STATUS_CONNECTING = 0;
const STATUS_OFFLINE = 1;
const STATUS_CONNECTED = 2;

var conn_attempts = 0;

var connected = false;
var timeoutId;
var global_ws = null;

var container_count = 0;

var proxy_map = {};

var web_response_whitelist = ["main_frame", "xmlhttprequest"];

const log_debug = true;

browser.browserAction.setBadgeBackgroundColor({
	color: [0, 0, 0, 0]
});

// helper functions
async function get_tabs(){
	
	var tabs = await browser.tabs.query({});
	
	return tabs.map(tab => ({
		id: tab.id,
		index: tab.index,
		status: tab.status,
		active: tab.active,
		title: tab.title,
		url: tab.url,
		container: tab.cookieStoreId
	}));
}

async function tab_exists(id){
	
	try{
		
		await browser.tabs.get(id);
		return true;
	}catch{
		
		return false;
	}
}

async function get_container_list(){
	
	const containers = await browser.contextualIdentities.query({});
	
	var list = [];
	for(var i=0; i<containers.length; i++){
		
		list.push({
			id: containers[i].cookieStoreId,
			name: containers[i].name,
			icon: containers[i].icon,
			color: containers[i].color,
			proxy: proxy_map[containers[i].cookieStoreId]
		});
	}
	
	return list;
}

async function container_exists(id){
	
	try{
		
		await browser.contextualIdentities.get(id);
		return true;
	}catch{
		
		return false;
	}
}

function send(ws, seqid, msg = {}){
	
	msg.seqid = seqid;
	var msg = JSON.stringify(msg);
	
	if(log_debug){ console.log("-> " + msg); }
	ws.send(msg);
}

function send_event(ws, msg = {}){
	
	var msg = JSON.stringify(msg);
	if(log_debug){ console.log("-> " + msg) };
	ws.send(msg);
}

async function set_status(status){
	
	switch(status){
		case STATUS_CONNECTING:
			conn_attempts++;
			
			browser.browserAction.setBadgeText({text: "🔵"});
			await browser.storage.local.set({"status": STATUS_CONNECTING, "attempts": conn_attempts});
			break;
		
		case STATUS_CONNECTED:
			conn_attempts = 0;
			
			browser.browserAction.setBadgeText({text: "🟢"});
			await browser.storage.local.set({"status": STATUS_CONNECTED, "attempts": 0});
			break;
		
		case STATUS_OFFLINE:
			browser.browserAction.setBadgeText({text: "🔴"});
			await browser.storage.local.set({"status": STATUS_OFFLINE});
			break;
	}
}

function ws_connect_timeout(url, timeoutMs = 5000){
	
	timeoutMs = parseInt(timeoutMs);
	
	return new Promise(function(resolve, reject){
		
		var ws = null;
		global_ws = null;
		
		try{
			
			ws = new WebSocket(url);
			
		}catch(error){
			
			setTimeout(async function(){
				
				ws_init();
				reject(new Error("Bad URL"));
			}, timeoutMs);
			return;
		}
		
		attach_ws_events(ws);
		/*
		ws.addEventListener("open", function(){console.log("open!");});
		ws.addEventListener("message", function(){console.log("message!");});
		ws.addEventListener("close", function(){console.log("close!");});*/
		
		connected = false;

		// Set up the timeout
		timeoutId = setTimeout(function(){
			if(!connected){
				
				ws.close();
				reject(new Error("Timeout"));
			}
		}, timeoutMs);

		ws.addEventListener("open", function(){
			connected = true;
			clearTimeout(timeoutId);
			resolve(ws);
		});

		ws.addEventListener("close", function(){
			
			clearTimeout(timeoutId);
			setTimeout(async function(){
				
				ws_init();
				reject(new Error("Close"));
			}, timeoutMs);
		});
	});
}

async function ws_init(){
	
	await set_status(STATUS_CONNECTING);
	var config = await browser.storage.local.get();
	
	try{
		
		global_ws = await ws_connect_timeout(config.ws_url, config.ws_timeout);
	}catch(error){
		
		console.log("ws: " + error);
		return;
	}
	
	// online
}

function attach_ws_events(ws){
	
	ws.addEventListener("open", async function(){
		
		console.log("ws: connected");
		await set_status(STATUS_CONNECTED);
	});
	
	ws.addEventListener("message", async function(e){
		
		if(log_debug){ console.log("<- " + e.data); }
		
		var msg = JSON.parse(e.data);
		var seqid = msg.seqid;
		
		switch(msg.action){
			
			//
			// Misc
			//
			case "get_ua":
				send(ws, seqid, {
					"ua": navigator.userAgent
				});
				break;
			
			case "web_response_whitelist":
				web_response_whitelist = msg.list;
				
				send(ws, seqid, {
					"status": true
				})
				break;
			
			//
			// Tabs
			//
			case "get_tabs":
				send(ws, seqid, {
					"tabs": await get_tabs()
				});
				break;
			
			case "tab_open":
				var tab =
					await browser.tabs.create({
						url: msg.url,
						...(typeof msg.container == "string" && { cookieStoreId: msg.container })
					});
				
				// immediately return even if its not loaded yet
				send(ws, seqid, {
					data: {
						id: tab.id,
						index: tab.index,
						status: tab.status,
						active: tab.active,
						title: tab.title,
						url: tab.url,
						container: tab.cookieStoreId
					}
				});
				break;
			
			case "tab_close":
				var closed_tabs = 0;
				
				switch(typeof msg.tabid){
					
					case "number":
						var exists = await tab_exists(msg.tabid);
						
						if(exists){
							await browser.tabs.remove(msg.tabid);
							closed_tabs = 1;
						}
						break;
					
					case "object":
						var exists = false;
						
						for(var i=0; i<msg.tabid.length; i++){
							
							exists = await tab_exists(msg.tabid[i]);
							
							if(exists){
								await browser.tabs.remove(msg.tabid[i]);
								closed_tabs++;
							}
						}
						break;
				}
				
				send(ws, seqid, {"closed_tab_count": closed_tabs});
				break;
			
			case "tab_focus":
				var exists = await tab_exists(msg.tabid);
				
				if(exists){
					
					await browser.tabs.update(msg.tabid, { active: true });
					send(ws, seqid, {"status": true});
					return;
				}
				
				send(ws, seqid, {"status": false});
				break;
			
			case "tab_exists":
				var exists = await tab_exists(msg.tabid);
				send(ws, seqid, {"exists": exists});
				break;
			
			case "tab_inject_js":
				try{
					
					var result = await browser.scripting.executeScript({
						target: { tabId: msg.tabid },
						func: (code) => eval(code),
						args: [msg.js],
						...(msg.isolated === true && { world: "ISOLATED" })
					});
					
					send(ws, seqid, {"status": true, "result": result});
				}catch(err){
					
					send(ws, seqid, {"status": err.name + ": " + err.message});
				}
				break;
			
			//
			// Containers
			//
			case "get_container_list":
				var containers = await get_container_list();
				
				send(ws, seqid, {
					"containers": containers
				});
				break;
			
			case "container_create":
				
				// generate random container attributes
				container_count++;
				
				var name = null;
				
				if(typeof msg.name != "undefined"){
					
					name = msg.name;
				}else{
					
					name = "sesh" + container_count;
				}
				
				const color = [
					"blue",
					"turquoise",
					"green",
					"yellow",
					"orange",
					"red",
					"pink",
					"purple"
				][Math.floor(Math.random() * 8)];
				
				const icon = [
					"fingerprint",
					"briefcase",
					"dollar",
					"cart",
					"circle",
					"gift",
					"vacation",
					"food",
					"fruit",
					"pet",
					"tree",
					"chill",
					"fence"
				][Math.floor(Math.random() * 13)];
				
				const container = await browser.contextualIdentities.create({
					name: name,
					color: color,
					icon: icon
				});
				
				proxy_map[container.cookieStoreId] = {
					type: "direct"
				};
				
				send(ws, seqid, {
					id: container.cookieStoreId,
					name: name,
					color: color,
					icon: icon,
					proxy: proxy_map[container.cookieStoreId]
				});
				
				break;
			
			case "container_exists":
				var exists = await container_exists(msg.id);
				send(ws, seqid, {"exists": exists});
				break;
			
			case "container_delete":
				var deleted_containers = 0;
				
				switch(typeof msg.id){
					
					case "number":
						var exists = await container_exists(msg.id);
						
						if(exists){
							await browser.contextualIdentities.remove(msg.id);
							delete(proxy_map[msg.id]);
							deleted_containers = 1;
						}
						break;
					
					case "object":
						var exists = false;
						
						for(var i=0; i<msg.id.length; i++){
							
							exists = await container_exists(msg.id[i]);
							
							if(exists){
								await browser.contextualIdentities.remove(msg.id[i]);
								delete(proxy_map[msg.id[i]]);
								deleted_containers++;
							}
						}
						break;
				}
				
				send(ws, seqid, {"closed_container_count": deleted_containers});
				break;
			
			case "container_attach_proxy":
				var status = await container_exists(msg.id);
				
				if(status){
					
					proxy_map[msg.id] = msg.proxy;
					send(ws, seqid, {status: true});
					return;
				}
				
				send(ws, seqid, {status: false});
				break;
			
			case "container_detach_proxy":
				var status = await container_exists(msg.id);
				
				if(status){
					
					proxy_map[msg.id] = {type: "direct"};
					send(ws, seqid, {status: true});
					return;
				}
				
				send(ws, seqid, {status: false});
				break;
			
			default:
				console.log(`ws: unhandled message "${msg.action}"`, msg);
				break;
		}
	});
	
	ws.addEventListener("close", async function(e){
		
		console.log("ws: offline");
		await set_status(STATUS_OFFLINE);
	});
}

//
// Page events
//
// log requests before they're sent
browser.webRequest.onSendHeaders.addListener(
	function(details){
		
		if(global_ws === null){ return; }
		
		var headers = [];
		
		for(const header of details.requestHeaders){
			
			headers.push(header.name + ": " + header.value);
		}
		
		send_event(
			global_ws,
			{
				"action": "web_request",
				"data": {
					id: details.tabId,
					url: details.url,
					status: details.statusCode,
					origin: details.originUrl,
					type: details.type,
					method: details.method,
					container: details.cookieStoreId,
					headers: headers
				}
			}
		);
	},
	{urls: ["<all_urls>"]/*, types: ["main_frame"]*/},
	["requestHeaders"]
);

// forward response body
async function buff2b64(uint8Array) {
	return new Promise(function(resolve, reject){
		const blob = new Blob([uint8Array]);
		const reader = new FileReader();

		reader.onload = function(){
			const base64 = reader.result.split(",")[1];
			resolve(base64);
		};

		reader.onerror = reject;
		reader.readAsDataURL(blob);
	});
}

browser.webRequest.onBeforeRequest.addListener(
	async function(details){
		
		if(
			web_response_whitelist.length === 0 ||
			global_ws === null
		){ return; }
		
		const filter = browser.webRequest.filterResponseData(
			details.requestId
		);
		
		var chunks = [];
		
		filter.ondata = async function(event){
			
			chunks.push(event.data);
			
			// forward response to browser untouched
			filter.write(event.data);
		};
		
		filter.onstop = async function(){
			
			// we got the full response data
			var len = 0;
			for(const c of chunks){
				
				len += c.byteLength;
			}
			
			const merged = new Uint8Array(len);
			
			let offset = 0;
			for(const c of chunks){
				
				merged.set(new Uint8Array(c), offset);
				offset += c.byteLength;
			}
			
			var b64 = await buff2b64(merged);
			
			send_event(
				global_ws,
				{
					action: "web_response",
					data: {
						id: details.tabId,
						url: details.url,
						status: details.statusCode,
						origin: details.originUrl,
						type: details.type,
						method: details.method,
						container: details.cookieStoreId,
						url: details.url,
						body: b64
					}
				}
			);
			
			filter.close();
		};
	},
	{ urls: ["<all_urls>"], types: web_response_whitelist },
	["blocking"]
);

browser.proxy.onRequest.addListener(function(request){
	
	const proxy_config = proxy_map[request.cookieStoreId];
	if(proxy_config){
		
		return proxy_config;
	}
	
	// fallback, should not happen
	return {
		type: "direct"
	}
},
{
	urls: ["<all_urls>"]
});

browser.tabs.onUpdated.addListener(function(tabid, event, tab){
	
	if(connected === false){ return; }
	
	if(event.status === "complete"){
		
		send_event(
			global_ws,
			{
				"action": "dom_ready",
				"data": {
					id: tab.id,
					index: tab.index,
					status: tab.status,
					active: tab.active,
					title: tab.title,
					url: tab.url,
					container: tab.cookieStoreId
				}
			}
		);
	}
});

browser.webNavigation.onErrorOccurred.addListener(function(page){
	
	if(connected === false){ return; }
	
	send_event(
		global_ws,
		{
			"action": "dom_load_fail",
			"data": {
				id: page.tabId
			}
		}
	);
});

(async function(){
	await ws_init();
})();
