# 4play
4play is a Firefox extension that lets you bot shit.

## Features
- Does not expose any `webdriver.*` variables, it's just an extension
- Environment is undetectable. Inject JavaScript through JS isolated worlds.
- Simple as fuck

## How it works
4play makes Firefox connects to a websocket server in the background. The server then sends commands to the browser. You can clean up containers, navigate to pages, inject javascript or extract raw page content & request headers.

## Fucking why?
It's a complete replacement for dogshit libraries like Puppeteer/Selenium/Playwright, which are developed by Google engineers. These libraries purposely leak bot signals even with the usage of stealth scripts. With this library, a single Firefox instance can use multiple proxies at the same time across multiple containers and completely avoid detection. Fuck your cat & mouse game, im tired of your shit.

I'm so fucking tired of retards recommending libraries that are so easily detectable. Just give me something that works you fucks.

## Installation
Install the 4play extension on a **CLEAN** Firefox install. Do **NOT** use your main profile, it will mess up your tabs and containers. Enter credentials in the extension and connect.

Just go get the extension on the [Firefox store](https://addons.mozilla.org/en-US/firefox/addon/4play/), or run it for development like so:

```sh
npm install --global web-ext
cd ext
web-ext run # this will launch a new firefox instance
```

Then, start the server:
```bash
cd server
npm install http ws
node hello-world.js
```

## Example server script

```js
const fplay = require("./fplay.js");

var port = 3030;
var timeout = 30000;

fplay.event.on("server_ready", function(){
	
	console.log("listening on port " + port + " (timeout=" + timeout + ")");
});

fplay.event.on("browser_connect", async function(ws){
	
	const ua = await fplay.get_ua(ws);
	console.log("Connection from " + ua);
	
	// clean up
	const blanktab = await fplay.close_all_tabs(ws);
	await fplay.delete_all_containers(ws);
	
	// create container
	const container = await fplay.container_create(ws);
	console.log(container);
	
	// assign proxy
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
	);
	
	// open tab
	const newtab = await fplay.tab_open(ws, "https://lolcat.ca", true, container);
	console.log(newtab);
	
	// get page's title
	var result = await fplay.tab_inject_js(ws, newtab, "document.title", true);
	
	console.log(result);
});

fplay.init(port, timeout);
```

# 4play API Reference

## Initialization

### `fplay.init(port?, command_timeout?)`

Starts the HTTP/WebSocket server.

- `port` (`number`, default: `3030`) - Port to listen on.
- `password` (`string`, default: `cnc`)  - Websocket path (acts as password)
- `command_timeout` (`number`, default: `5000`) - Timeout in ms for commands sent to the browser.

**Returns:** `void`

---

## Misc

### `fplay.get_ua(ws)`

Gets the browser's user agent string.

- `ws` (`WebSocket`) - Active browser connection.

**Returns:** `string` on success, `false` on failure.

### `fplay.web_response_whitelist(sources)`

Outputs the raw body of incoming pages for `fplay.event.on("web_response", ...)`. `sources` defines what data sources will be returned: `main_frame`, `sub_frame`, `stylesheet`, `script`, `image`, `object`, `xmlhttprequest`, `ping`, `font`, `media`, `websocket`, `csp_report`, `imageset`, `web_manifest`, `speculative` and `other`

Default is `main_frame`, `xmlhttprequest`.

**Returns:** `boolean` `true`.

### `fplay.wait_random(min, max)`

Waits for an inclusive amount of time in miliseconds.

**Returns:** `boolean` `true`.

### `fplay.parse_cookies(headers)`

Extracts a `key => value` cookie pair from raw headers.

- `headers` (`Array`) - List of header strings

**Returns:** `Array: key => value`.

---

## Tabs

### `fplay.get_tab_list(ws)`

Gets a list of all open tabs.

- `ws` (`WebSocket`) - Active browser connection.

**Returns:** `Array<object>` on success (each object contains `id`, `index`, `status`, `active`, `title`, `url`, `container`), `false` on failure.

### `fplay.tab_open(ws, url, await_dom_ready?, container?)`

Opens a new tab.

- `ws` (`WebSocket`) - Active browser connection.
- `url` (`string`) - URL to open.
- `await_dom_ready` (`boolean`, default: `false`) - If `true`, waits for the page to fully load before resolving.
- `container` (`object | string | null`, default: `null`) - Container to open the tab in. Accepts a container object (with `.id`) or a raw container object.

**Returns:** `object` (tab data: `id`, `index`, `status`, `active`, `title`, `url`, `container`) on success, `false` on failure.

### `fplay.tab_close(ws, tab_ids)`

Closes one or more tabs.

- `ws` (`WebSocket`) - Active browser connection.
- `tab_ids` (`number | number[] | object`) - Tab ID, array of tab IDs, or a tab object (with `.id`).

**Returns:** `number` (count of closed tabs) on success, `false` on failure.

### `fplay.close_all_tabs(ws)`

Closes all tabs except a newly opened blank tab.

- `ws` (`WebSocket`) - Active browser connection.

**Returns:** `object` - The new blank tab's data.

### `fplay.tab_focus(ws, tabid)`

Focuses (activates) a tab.

- `ws` (`WebSocket`) - Active browser connection.
- `tabid` (`number | object`) - Tab ID or tab object (with `.id`).

**Returns:** `boolean` - `true` if focused successfully, `false` otherwise.

### `fplay.tab_exists(ws, tabid)`

Checks whether a tab exists.

- `ws` (`WebSocket`) - Active browser connection.
- `tabid` (`number | object`) - Tab ID or tab object (with `.id`).

**Returns:** `boolean` - `true` if the tab exists, `false` otherwise.

### `fplay.tab_inject_js(ws, tabid, js, isolated?)`

Injects and executes JavaScript in a tab.

- `ws` (`WebSocket`) - Active browser connection.
- `tabid` (`number | object`) - Tab ID or tab object (with `.id`).
- `js` (`string`) - JavaScript code to execute.
- `isolated` (`boolean`, default: `false`) - If `true`, runs in an isolated world. See MDN for more info.

**Returns:** `object` - `{ status: true, result: any }` on success, `{ status: string, result: null }` on error (status contains the error message), `{ status: false, result: null }` on failure.

---

## Containers

### `fplay.container_create(ws, name?)`

Creates a new container with a random color and icon.

- `ws` (`WebSocket`) - Active browser connection.
- `name` (`string | null`, default: `null`) - Container name. If `null`, auto-generates a name (`sesh1`, `sesh2`, etc.).

**Returns:** `object` (`id`, `name`, `color`, `icon`, `proxy`) on success, `false` on failure.

### `fplay.get_container_list(ws)`

Gets a list of all containers.

- `ws` (`WebSocket`) - Active browser connection.

**Returns:** `Array<object>` on success (each object contains `id`, `name`, `icon`, `color`, `proxy`), `false` on failure.

### `fplay.container_delete(ws, id)`

Deletes one or more containers.

- `ws` (`WebSocket`) - Active browser connection.
- `id` (`string | string[] | object`) - Container ID, array of container IDs, or a container object (with `.id`).

**Returns:** `number` (count of deleted containers) on success, `false` on failure.

### `fplay.container_exists(ws, id)`

Checks whether a container exists.

- `ws` (`WebSocket`) - Active browser connection.
- `id` (`string | object`) - Container ID or container object (with `.id`).

**Returns:** `boolean` - `true` if the container exists, `false` otherwise.

### `fplay.delete_all_containers(ws)`

Deletes all containers.

- `ws` (`WebSocket`) - Active browser connection.

**Returns:** `number` - Count of deleted containers.

### `fplay.container_attach_proxy(ws, id, proxy)`

Attaches a proxy configuration to a container.

- `ws` (`WebSocket`) - Active browser connection.
- `id` (`string | object`) - Container ID or container object (with `.id`).
- `proxy` (`object`) - Proxy configuration object:
  - `type` (`string`) - `"socks"`, `"socks4"`, `"http"`, or `"https"`
  - `host` (`string`) - Proxy host
  - `port` (`number`) - Proxy port
  - `username` (`string`, optional) - Proxy username
  - `password` (`string`, optional) - Proxy password
  - `proxyDNS` (`boolean`, optional) - Whether to proxy DNS lookups

**Returns:** `boolean` - `true` if attached successfully, `false` otherwise.

### `fplay.container_detach_proxy(ws, id)`

Removes the proxy from a container, reverting to direct connection.

- `ws` (`WebSocket`) - Active browser connection.
- `id` (`string | object`) - Container ID or container object (with `.id`).

**Returns:** `boolean` - `true` if detached successfully, `false` otherwise.

---

## Events

### `fplay.wait_for_dom_ready(tabid)`

Returns a promise that resolves when a tab's DOM finishes loading.

- `tabid` (`number`) - Tab ID to wait on.

**Returns:** `Promise<object>` - Resolves with tab data on success, `false` on load failure.

### `fplay.event`

An `EventEmitter` instance that emits the following events:

| Event | Data | Description |
|---|---|---|
| `server_ready` | `{}` | Server started listening |
| `browser_connect` | `ws` | Browser connected |
| `browser_disconnect` | `{}` | Browser disconnected |
| `dom_ready` | `{ id, index, status, active, title, url, container }` | A tab finished loading |
| `dom_load_fail` | `{ id }` | A tab failed to load |
| `web_request` | `{ id, url, status, origin, type, method, container, headers }` | A request was sent |
| `web_response` | `{ id, url, status, origin, type, method, container, body }` | A response was received |

---

## Properties

| Property | Type | Description |
|---|---|---|
| `fplay.browser_connected` | `boolean` | Whether the browser extension is currently connected |
| `fplay.PORT` | `number` | Current server port |
| `fplay.COMMAND_TIMEOUT` | `number` | Current command timeout in ms |
| `fplay.PASSWORD` | `string` | Server password |

# License
AGPLv3
