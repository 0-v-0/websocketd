# Websocket Server

This is a _dubization_ of  [George Zakhour web socket server](https://github.com/geezee/websocket-d-server)

# Usage
To start, every connected peer receives an ID whose type is `PeerID`.

To implement a protocol, you start by creating a subclass of `WebSocketServer`.

And you will have to implement four methods:
* `override void onOpen(WSClient client, Request req)` which is executed every time a client connects to
  the websocket server. The `id` argument is the generated ID of the newly connected client, the
  `path` argument is the path the client connects to.
* `override void onClose(WSClient client)` which is executed everytime a client disconnects.
* `override void onTextMessage(WSClient client, string msg)` which is executed every time a TEXT message
  from a client `id` is received.
* `override void onBinaryMessage(WSClient client, ubyte[] msg)` which is executed every time a BINARY message
  from a client `id` is received.

To run the server you need to execute the `run(size_t bufferSize = 1024)(ushort port)` method on the
server instance. The `port` template argument is the port the server needs to run, and the
`maxConnections` template argument is the maximum number of allowed connections. When the maximum
number of connections is reached every new connection will be denied.

To send a message to a peer whose id is `id`, you can use `send(WSClient client, string|ubyte[] msg)`


# Examples
Some examples can be found in `test_server.d` which are recreated here.

## Echo server

```
class EchoSocketServer : WSServer {
    override void onOpen(WSClient client, Request req) {
		try tracef("Peer %s connect to '%s'", client.id, req.path); catch(Exception) {}
	}

	override void onTextMessage(WSClient client, string msg) {
		try {
			tracef("Received message from %s", client.id);
			tracef("         message: %s", msg);
			tracef("         message length: %d", msg.length);
			client.send(msg);
		} catch(Exception) {}
	}
}
```
To run `echo` version:
```
$ cd examples
$ dub run -cecho
```

In order to test we can use [websocat](https://lib.rs/crates/websocat)
```
$ websocat ws://127.0.0.1:10301
```
If you use nginx you can create a proxy:

```
location /ws {
	proxy_pass http://127.0.0.1:10301;
}

```
so:
```
$ websocat ws://127.0.0.1/ws
```

## Broadcasting server based on the connected path

Clients can subscribe to the channel `xyz` by connecting to `ws://example.com/xyz`. Clients connected
to another channel (eg. `abc`) will not receive messages from other channels (eg. `xyz`).

```
class BroadcastServer : WSServer {
	private string[PeerID] peers;

	override void onOpen(WSClient client, Request req) {
		peers[client.id] = req.path;
	}

	override void onClose(WSClient client) {
		peers.remove(client.id);
	}

	override void onTextMessage(WSClient client, string msg) {
		auto src = client.id;
		auto srcPath = peers[src];
		try
			foreach (id, path; peers)
				if (id != src && path == srcPath)
					send(clients[id], msg);
		catch(Exception) {}
	}

	override void onBinaryMessage(WSClient client, ubyte[] msg) {
		auto src = client.id;
		auto srcPath = peers[src];
		try
			foreach (id, path; peers)
				if (id != src && path == srcPath)
					send(clients[id], msg);
		catch(Exception) {}
	}
}
```

To run `broadcast` version:
```
$ cd examples
$ dub run -cbroadcast
```

# Running the server with TLS

The server natively does not support TLS. However if you use nginx you can create a proxy and use
nginx for TLS. Here's an example of an nginx configuration.

```
upstream websocketservers {
	server localhost:10301; # 10301 being the port websocket-d-server runs on
}

server {
	server_name example.com;
	# ...

	location /<path> {
		proxy_pass http://websocketservers;
	}

	listen 443 ssl;
	# ...
}
```

Then a client can connect via `wss://example.com/`
