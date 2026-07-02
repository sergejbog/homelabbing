const http = require("http");
const { WebSocketServer } = require("ws");

var fplay = {};

fplay.PORT = 3030;
fplay.COMMAND_TIMEOUT = 5000;
fplay.PASSWORD = "cnc";

const { EventEmitter } = require("events");
fplay.event = new EventEmitter();

fplay.server = http.createServer(function(req, res){
	
	switch(req.url){
		
		case "/" + fplay.PASSWORD:
			res.writeHead(426, { "Content-Type": "application/json" });
			res.end(JSON.stringify({"status": "No websocket upgrade received"}));
			break;
		
		default:
			res.writeHead(404, { "Content-Type": "application/json" });
			res.end(JSON.stringify({ "status": "Invalid endpoint" }));
	}
});

fplay.wss = new WebSocketServer({ server: fplay.server, path: "/" + fplay.PASSWORD });

fplay.seqid = 0;
fplay.pending = new Map(); // promise map
fplay.pending_dom_ready = new Map();

// helper functions
fplay.send = async function(ws, action, msg = {}){
	
	const seqid = ++fplay.seqid;
	msg.action = action;
	msg.seqid = seqid;
	
	return new Promise(function(resolve){
		
		const timer = setTimeout(function(){
			fplay.pending.delete(seqid);
			resolve(false);
		}, fplay.COMMAND_TIMEOUT);

		fplay.pending.set(seqid, {
			resolve: function(data){ clearTimeout(timer); resolve(data); },
			reject: function(){ clearTimeout(timer); resolve(false); }
		});
		
		ws.send(JSON.stringify(msg));
	});
}

fplay.wait_random = async function(min, max){
	
	return new Promise(function(resolve){
		
		setTimeout(function(){
			
			resolve(true);
		}, min + Math.round(Math.random() * (max - min)))
	});
}

fplay.parse_cookies = function(headers){
	
	var cookies = {};
	
	headers.forEach(function(header){
		
		var cookie = header.split(":")
		var header_name = cookie.shift();
		
		if(header_name.toLowerCase() != "cookie"){ return; } // continue;
		
		cookie = cookie.join(":").split(";");
		
		cookie.forEach(function(c){
			
			c = c.split("=");
			var key = c.shift().trim();
			var value = c.join("=");
			
			cookies[key] = value;
		});
	});
	
	return cookies;
}

//
// Misc protocol functions
//
fplay.get_ua = async function(ws){
	
	var ua = await fplay.send(ws, "get_ua");
	
	if(typeof ua.ua == "string"){
		
		return ua.ua;
	}
	
	return false;
}



//
// Tab functions
//
fplay.get_tab_list = async function(ws){
	
	var tabs = await fplay.send(ws, "get_tabs");
	
	if(typeof tabs.tabs == "object"){
		
		return tabs.tabs;
	}
	
	return false;
}

fplay.tab_open = async function(ws, url, await_dom_ready = false, container = null){
	
	var data = {
		url: url
	};
	
	if(container !== null){
		
		if(
			typeof container == "object" &&
			typeof container.id != "undefined"
		){
			
			data.container = container.id;
		}
		
		if(typeof container == "string"){
			
			data.container = container;
		}
	}
	
	var newtab = await fplay.send(ws, "tab_open", data);
	
	if(typeof newtab.data == "object"){
		
		if(await_dom_ready){
			
			var data = await fplay.wait_for_dom_ready(newtab.data.id);
			return data;
		}
		
		return newtab.data;
	}
	
	return false;
}

// @ tab_ids: number, array or tab object
fplay.tab_close = async function(ws, tab_ids){
	
	if(
		typeof tab_ids == "object" &&
		typeof tab_ids.id == "number"
	){
		
		tab_ids = tab_ids.id;
	}
	
	var closed_tab_count = await fplay.send(ws, "tab_close", {"tabid": tab_ids});
	
	if(typeof closed_tab_count.closed_tab_count == "number"){
		
		return closed_tab_count.closed_tab_count;
	}
	
	return false;
}

fplay.close_all_tabs = async function(ws){
	
	const tabs = await fplay.get_tab_list(ws);
	const newtab = await fplay.tab_open(ws, "about:blank");
	
	// clean up useless tabs
	var tabs_to_close = [];
	
	for(var i=0; i<tabs.length; i++){
		
		if(tabs[i].id !== newtab.id){
			
			tabs_to_close.push(tabs[i].id);
		}
	}
	
	await fplay.tab_close(ws, tabs_to_close);
	
	return newtab;
}

fplay.tab_focus = async function(ws, tabid){
	
	if(
		typeof tabid == "object" &&
		typeof tabid.id == "number"
	){
		
		var id = tabid.id;
	}else{
		
		var id = tabid;
	}
	
	var tab_state = await fplay.send(ws, "tab_focus", {"tabid": id});
	
	if(typeof tab_state.status == "boolean"){
		
		return tab_state.status;
	}
	
	return false;
}

fplay.tab_exists = async function(ws, tabid){
	
	if(
		typeof tabid == "object" &&
		typeof tabid.id == "number"
	){
		
		var id = tabid.id;
	}else{
		
		var id = tabid;
	}
	
	var tab_state = await fplay.send(ws, "tab_exists", {"tabid": id});
	
	if(typeof tab_state.exists == "boolean"){
		
		return tab_state.exists;
	}
	
	return false;
}

fplay.tab_inject_js = async function(ws, tabid, js, isolated = false){
	
	if(
		typeof tabid == "object" &&
		typeof tabid.id == "number"
	){
		
		var id = tabid.id;
	}else{
		
		var id = tabid;
	}
	
	var tab_state = await fplay.send(ws, "tab_inject_js", {"tabid": id, "js": js, "isolated": isolated});
	
	if(typeof tab_state.status != "undefined"){
		
		if(tab_state.status === true){
			
			return {
				status: true,
				result: tab_state.result
			};
		}
		
		return {
			status: tab_state.status,
			result: null
		}
	}
	
	return {
		status: false,
		result: null
	};
}

fplay.web_response_whitelist = async function(ws, sources = ["main_frame", "xmlhttprequest"]){
	
	var whitelist_status = await fplay.send(ws, "web_response_whitelist", {"list": sources});
	
	if(typeof whitelist_status.status === "boolean"){
		
		return whitelist_status.status;
	}
	
	return false;
}



//
// Container functions
//
fplay.container_create = async function(ws, name = null){
	
	if(name === null){
		
		var data = {};
	}else{
		
		var data = {
			name: name
		};
	}
	
	var container = await fplay.send(ws, "container_create", data);
	
	if(typeof container == "object"){
		
		return container;
	}
	
	return false;
}

fplay.get_container_list = async function(ws){
	
	var containers = await fplay.send(ws, "get_container_list");
	
	if(typeof containers.containers == "object"){
		
		return containers.containers;
	}
	
	return false;
}

// accepts container object, array of ids or raw id
fplay.container_delete = async function(ws, id){
	
	if(
		typeof id == "object" &&
		typeof id.id != "undefined"
	){
		
		id = id.id;
	}
	
	var container_state = await fplay.send(ws, "container_delete", {"id": id});
	
	if(typeof container_state.closed_container_count == "number"){
		
		return container_state.closed_container_count;
	}
	
	return false;
}

fplay.container_exists = async function(ws, id){
	
	if(
		typeof id == "object" &&
		typeof id.id != "undefined"
	){
		
		id = id.id;
	}
	
	var container_state = await fplay.send(ws, "container_exists", {"id": id});
	
	if(typeof container_state.exists == "boolean"){
		
		return container_state.exists;
	}
	
	return false;
}

fplay.delete_all_containers = async function(ws){
	
	var list = await fplay.get_container_list(ws);
	
	var containers_to_delete = [];
	
	for(var i=0; i<list.length; i++){
		
		containers_to_delete.push(list[i].id);
	}
	
	var count = await fplay.container_delete(ws, containers_to_delete);
	return count;
}

/*
proxy object can look like this
{
	type: "socks", // socks(is socks5) http, https, socks4
	host: "127.0.0.1",
	port: 1080,
	username: "myuser",
	password: "mypassword",
	proxyDNS: true,
}
*/
fplay.container_attach_proxy = async function(ws, id, proxy){
	
	if(
		typeof id == "object" &&
		typeof id.id != "undefined"
	){
		
		id = id.id;
	}
	
	var proxy_success = await fplay.send(ws, "container_attach_proxy", {"id": id, "proxy": proxy});
	
	if(typeof proxy_success.status == "boolean"){
		
		return proxy_success.status;
	}
	
	return false;
}

fplay.container_detach_proxy = async function(ws, id){
	
	if(
		typeof id == "object" &&
		typeof id.id != "undefined"
	){
		
		id = id.id;
	}
	
	var proxy_success = await fplay.send(ws, "container_detach_proxy", {"id": id});
	
	if(typeof proxy_success.status == "boolean"){
		
		return proxy_success.status;
	}
	
	return false;
}


//
// Unsolicited event handlers
//
fplay.wait_for_dom_ready = async function(tabid){
	
	return new Promise(function(resolve){
		
		fplay.pending_dom_ready.set(
			tabid,
			{
				resolve: resolve,
				reject: function(){ resolve(false); }
			}
		);
	});
}

fplay.dom_is_ready = function(tabid, data){
	
    const promise = fplay.pending_dom_ready.get(tabid);
    
    if(promise){
		
        fplay.pending_dom_ready.delete(tabid);
        promise.resolve(data);
    }
}

fplay.event.on("dom_ready", function(data){
	
    const promise = fplay.pending_dom_ready.get(data.id);
    
    if(promise){
		
        fplay.pending_dom_ready.delete(data.id);
        promise.resolve(data);
    }
});
/*
fplay.event.on("web_response", function(data){
	
	console.log(data);
});*/

fplay.event.on("dom_load_fail", function(data){
	
    const promise = fplay.pending_dom_ready.get(data.id);
    
    if(promise){
		
        fplay.pending_dom_ready.delete(data.id);
        promise.reject();
    }
});

// log requests
/*
fplay.event.on("web_request", function(page){
	
	console.log(page);
});*/

fplay.browser_connected = false;

fplay.wss.on("connection", async function(ws){
	
	fplay.browser_connected = true;
	fplay.event.emit("browser_connect", ws);
	
	// register user events
	ws.on("message", async function(msg){
		
		msg = JSON.parse(msg.toString());
		
		//console.log(msg);
		
		if(typeof msg.seqid == "number"){
			
			// resolve promises
			fplay.pending.get(msg.seqid).resolve(msg);
			fplay.pending.delete(msg.seqid);
			return;
		}
		
		if(msg.action == "web_response"){
			
			// decode base64 as a buffer
			msg.data.body = Buffer.from(msg.data.body, "base64");
		}
		
		// any other message should be an unsolicited event
		fplay.event.emit(msg.action, msg.data);
	});

	ws.on("close", async function(){
		
		fplay.browser_connected = false;
		fplay.event.emit("browser_disconnect", {});
	});
});

fplay.init = function(port = 3030, password = "cnc", command_timeout = 5000){
	
	fplay.PORT = port;
	fplay.COMMAND_TIMEOUT = command_timeout;
	fplay.PASSWORD = password;
	
	fplay.server.listen(fplay.PORT, function(){
		
		fplay.event.emit("server_ready", {});
	});
}

module.exports = fplay;
