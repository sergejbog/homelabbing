const fplay = require("./lib/fplay.js");

var port = 3030;
var timeout = 30000;
var password = "cnc";

fplay.event.on("server_ready", function(){
	
	console.log("listening on port " + port + " (timeout=" + timeout + ")");
});

fplay.event.on("browser_connect", async function(ws){
	
	const ua = await fplay.get_ua(ws);
	console.log("Connection from " + ua);
	
	// clean up
	const blanktab = await fplay.close_all_tabs(ws);
	await fplay.delete_all_containers(ws);
	
	// only return responses for these data sources
	fplay.web_response_whitelist(ws, ["main_frame", "xmlhttprequest"]);
	
	// create container
	const container = await fplay.container_create(ws);
	console.log(container);
	
	// assign proxy
	/*
	await fplay.container_attach_proxy(
		ws,
		container,
		{
			type: "socks", // socks(is socks5) http, https, socks4
			host: "whatever-proxy-host-you-want.io",
			port: 1339,
			username: "admin",
			password: "1234",
			proxyDNS: true,
		}
	);*/
	
	// open tab
	const newtab = await fplay.tab_open(ws, "https://lolcat.ca", true, container);
	console.log(newtab);
	
	// get page's title
	var result = await fplay.tab_inject_js(ws, newtab, "document.title", true);
	
	console.log(result);
});

fplay.event.on("web_request", async function(request){
	
	//console.log(request);
});

fplay.event.on("web_response", async function(response){
	
	console.log(response);
});

fplay.init(port, password, timeout);
