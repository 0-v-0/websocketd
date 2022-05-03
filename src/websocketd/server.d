module websocketd.server;

import async.net.tcplistener,
std.socket,
std.experimental.logger,
websocketd.frame,
websocketd.request;

alias
PeerID = int,
ReqHandler = void function(WSServer, WSClient, in Request),
WSServer = WebSocketServer;

struct WSClient {
	Socket socket;
	alias socket this;

	@property auto id() {
		return cast(int)handle;
	}

	int send(T)(in T msg) {
		import std.traits;

		static if (isSomeString!T) {
			import std.string : representation;

			auto bytes = msg.representation;
			auto frame = Frame(true, Op.TEXT, false, State.done, [0, 0, 0, 0], msg.length, bytes);
		} else {
			alias bytes = msg;
			auto frame = Frame(true, Op.BINARY, false, State.done, [0, 0, 0, 0], msg.length, msg);
		}
		auto data = frame.serialize;
		try {
			tracef("Sending %u bytes to #%d in one frame of %u bytes long", bytes.length, id, data
					.length);
			return cast(int)socket.send(data);
		} catch (Exception)
			return -1;
	}
}

class WebSocketServer {
	import async.container.map;

	TcpListener listener;
	protected Map!(PeerID, Frame[]) map;
	Map!(PeerID, Socket) clients;
	ReqHandler handler;
	size_t maxConnections = 1000;

	this() {
		map = new typeof(map);
		clients = new typeof(clients);
	}
	// dfmt off
	void onOpen(WSClient, Request) nothrow {}
	void onClose(WSClient) nothrow {}
	void onTextMessage(WSClient, string) nothrow {}
	void onBinaryMessage(WSClient, ubyte[]) nothrow {}

	void add(Socket socket) nothrow {
		if (clients.length > maxConnections) {
			try infof("Maximum number of connections reached (%u)", maxConnections); catch(Exception) {}
			socket.close();
		} else
			clients[WSClient(socket).id] = socket;
	}

	void remove(int id) nothrow {
		map.remove(id);
		if (auto client = clients[id]) {
			onClose(WSClient(client));
			try infof("Closing connection #%d", id); catch(Exception) {}
			client.shutdown(SocketShutdown.BOTH);
			client.close();
		}
		clients.remove(id);
	}

	// dfmt on
	void run(size_t bufferSize = 1024)(ushort port) {
		import std.datetime;

		listener = new TcpListener;
		listener.bind(new InternetAddress("127.0.0.1", port));
		listener.listen(128);

		infof("Listening on port: %u", port);
		infof("Maximum allowed connections: %u", maxConnections);

		auto set = new SocketSet(maxConnections + 1);
		for (;;) {
			set.add(listener.socket);
			foreach (s; clients)
				set.add(s);
			Socket.select(set, null, null, 30.seconds);

			foreach (socket; clients) {
				if (!set.isSet(socket))
					continue;
				ubyte[bufferSize] buffer = void;
				long receivedLength = socket.receive(buffer[]);
				if (receivedLength > 0)
					onReceive(WSClient(socket), buffer[0 .. receivedLength]);
				else
					remove(WSClient(socket).id);
			}

			if (set.isSet(listener.socket))
				add(listener.accept());

			set.reset();
		}
	}

	int send(T)(Socket socket, T msg) {
		return WSClient(socket).send(msg);
	}

	bool performHandshake(WSClient client, in ubyte[] msg, out Request req) nothrow {
		import sha1ct : sha1Of;
		import std.conv : to;
		import std.uni : toLower;
		import tame.base64 : encode;

		enum MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
			KEY = "Sec-WebSocket-Key".toLower,
			KEY_MAXLEN = 192 - MAGIC.length;
		req = Request.parse(msg);
		if (!req.done)
			return false;

		auto key = KEY in req.headers;
		if (!key || key.length > KEY_MAXLEN) {
			if (handler)
				try
					handler(this, client, req);
				catch (Exception) {
				}
			return false;
		}
		auto len = key.length;
		char[256] buf = void;
		buf[0 .. len] = *key;
		buf[len .. len + MAGIC.length] = MAGIC;
		try {
			auto socket = client.socket;
			if (socket.send(
					"HTTP/1.1 101 Switching Protocol\r\n" ~
					"Upgrade: websocket\r\n" ~
					"Connection: Upgrade\r\n" ~
					"Sec-WebSocket-Accept: ") < 0 ||
				socket.send(encode(sha1Of(buf[0 .. len + MAGIC.length]), buf)) < 0 ||
				socket.send("\r\n\r\n") < 0)
				return false;
		} catch (Exception)
			return false;
		int id = client.id;
		if (map[id])
			map[id].length = 0;
		else {
			Frame[] frames;
			frames.reserve(1);
			map[id] = frames;
		}
		return true;
	}

private nothrow:
	void onReceive(WSClient client, const scope ubyte[] data) @trusted {
		import std.algorithm : swap;

		try
			tracef("Received %u bytes from %d", data.length, client.id);
		catch (Exception) {
		}

		if (map[client.id].ptr) {
			int id = client.id;
			Frame prevFrame = id.parse(data);
			for (;;) {
				handleFrame(WSClient(client), prevFrame);
				auto newFrame = id.parse([]);
				if (newFrame == prevFrame)
					break;
				swap(newFrame, prevFrame);
			}
		} else {
			Request req = void;
			if (performHandshake(client, data, req)) {
				try
					infof("Handshake with %d done (path=%s)", client.id, req.path);
				catch (Exception) {
				}
				onOpen(WSClient(client), req);
			}
		}
	}

	void handleFrame(WSClient client, Frame frame) {
		try
			tracef("From client %s received frame: done=%s; fin=%s; op=%s; length=%u",
				client.id, frame.done, frame.fin, frame.op, frame.length);
		catch (Exception) {
		}
		if (!frame.done)
			return;
		switch (frame.op) {
		case Op.CONT:
			return handleCont(client, frame);
		case Op.TEXT:
			return handle!false(client, frame);
		case Op.BINARY:
			return handle!true(client, frame);
		case Op.PING:
			enum pong = Frame(true, Op.PONG, false, State.done, [0, 0, 0, 0], 0, [
					]).serialize;
			try
				client.send(pong);
			catch (Exception) {
			}
			return;
		case Op.PONG:
			try
				tracef("Received pong from %s", client.id);
			catch (Exception) {
			}
			return;
		default:
			return remove(client.id);
		}
	}

	import std.array, std.format;

	void handleCont(WSClient client, Frame frame)
	in (!client.id || map[client.id], "Client #%d is used before handshake".format(client.id)) {
		if (!frame.fin) {
			if (frame.data.length)
				map[client.id] ~= frame;
			return;
		}
		auto frames = map[client.id];
		Op originalOp = frames[0].op;
		auto data = appender!(ubyte[])();
		data.reserve(frames.length);
		foreach (f; frames)
			data ~= f.data;
		data ~= frame.data;
		map[client.id].length = 0;
		if (originalOp == Op.TEXT)
			onTextMessage(client, cast(string)data[]);
		else if (originalOp == Op.BINARY)
			onBinaryMessage(client, data[]);
	}

	void handle(bool binary)(WSClient client, Frame frame)
	in (!map[client.id].length, "Protocol error") {
		if (frame.fin) {
			static if (binary)
				onBinaryMessage(client, cast(ubyte[])frame.data);
			else
				onTextMessage(client, cast(string)frame.data);
		} else
			map[client.id] ~= frame;
	}
}
