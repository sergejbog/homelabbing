
// this code triggers on popup load

const STATUS_CONNECTING = 0;
const STATUS_OFFLINE = 1;
const STATUS_CONNECTED = 2;

document.addEventListener('DOMContentLoaded', async function(){
	
	// generate initial config
	var config = await browser.storage.local.get();
	
	if(typeof config.ws_url == "undefined"){
		
		await browser.storage.local.set({"ws_url": "ws://localhost:3030/cnc"});
	}
	
	if(typeof config.ws_timeout == "undefined"){
		
		await browser.storage.local.set({"ws_timeout": 5000});
	}
	
	// update form
	config = await browser.storage.local.get(); // refresh first
	
	var form = document.getElementsByClassName("content")[0];
	
	var form_ws_url = document.getElementsByName("ws_url")[0];
	var form_ws_timeout = document.getElementsByName("ws_timeout")[0];
	
	form_ws_url.value = config.ws_url;
	form_ws_timeout.value = config.ws_timeout;
	
	// attach events to both form inputs to update config
	form_ws_url.addEventListener("input", async function(){
		
		await browser.storage.local.set({"ws_url": form_ws_url.value});
	});
	
	form_ws_timeout.addEventListener("input", async function(e){
		
		form_ws_timeout.value = form_ws_timeout.value.replaceAll(/[^0-9]/g, "");
		var timeout = form_ws_timeout.value;
		
		if(form_ws_timeout.value == ""){
			
			timeout = 5000;
		}
		
		await browser.storage.local.set({"ws_timeout": timeout});
	});
	
	// show the websocket status
	await html_gen_status();
	
	setInterval(async function(){
		
		await html_gen_status();
	}, 1000);
});

async function html_gen_status(){
	
	var dom_status = document.getElementById("status");
	var icon_path = null;
	var text = null;
	
	var config = await browser.storage.local.get();
	
	switch(config.status){
		
		case STATUS_CONNECTING:
			icon_path = "connecting";
			text = `Connecting... Attempt #${config.attempts}`;
			break;
		
		case STATUS_CONNECTED:
			icon_path = "connected";
			text = `Connected &amp; ready to kick ass`;
			break;
		
		case STATUS_OFFLINE:
			icon_path = "offline";
			text = `C&amp;C unreachable. Attempt #${config.attempts}`;
			break;
	}
	
	dom_status.innerHTML = `<img src="icons/${icon_path}.png">${text}`;
}
