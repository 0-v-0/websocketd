module websocketd.server;

import
	async,
	std.array,
	std.socket,
	std.experimental.logger,
	websocketd.frame,
	websocketd.request;

alias
	PeerID = int,
	ReqHandler = void function(WSServer, WSClient, in Request),
	WSServer = WebSocketServer;

struct WSClient {
	TcpClient client;
	alias client this;

	@property auto id() { return fd; }

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
			tracef("Sending %u bytes to #%d in one frame of %u bytes long", bytes.length, id, data.length);
			return client.send(data);
		} catch(Exception) return -1;
	}
}

class WebSocketServer : EventLoop {
	import async.container.map;

	protected Map!(PeerID, Frame[]) map;
	ReqHandler handler;

	void onOpen(WSClient, Request) nothrow {}
	void onClose(WSClient) nothrow {}
	void onTextMessage(WSClient, string) nothrow {}
	void onBinaryMessage(WSClient, ubyte[]) nothrow {}

	this(uint workerThreadNum = 0)
	{
		this(new TcpListener, workerThreadNum);
	}

	this(TcpListener listener, uint workerThreadNum = 0)
	{
		super(listener, null, null, &onReceive, null, null, null, workerThreadNum);
		map = new Map!(PeerID, Frame[]);
	}

	override void removeClient(int fd, int err = 0) {
		map.remove(fd);
		onClose(WSClient(clients[fd]));
		try infof("Closing connection #%d", fd); catch(Exception) {}
		super.removeClient(fd, err);
	}

	void run(ushort port) {
		_listener.bind(new InternetAddress("127.0.0.1", port));
		_listener.listen(128);
		super.run();
	}

	int send(T)(TcpClient client, T msg) {
		return WSClient(client).send(msg);
	}

	bool performHandshake(TcpClient client, in ubyte[] msg, out Request req) nothrow {
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
					handler(this, WSClient(client), req);
				catch (Exception) {}
			return false;
		}
		auto len = key.length;
		char[256] buf = void;
		buf[0 .. len] = *key;
		buf[len .. len + MAGIC.length] = MAGIC;
		try {
			if (client.send(
					"HTTP/1.1 101 Switching Protocol\r\n" ~
					"Upgrade: websocket\r\n" ~
					"Connection: Upgrade\r\n" ~
					"Sec-WebSocket-Accept: ") < 0 ||
				client.send(encode(sha1Of(buf[0 .. len + MAGIC.length]), buf)) < 0 ||
				client.send("\r\n\r\n") < 0)
			return false;
		} catch (Exception)
			return false;
		int id = client.fd;
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
	void onReceive(TcpClient client, const scope ubyte[] data) @trusted {
		import std.algorithm : swap;

		try tracef("Received %u bytes from %d", data.length, client.fd); catch(Exception) {}

		if (map[client.fd].ptr) {
			int id = client.fd;
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
				try infof("Handshake with %d done (path=%s)", client.fd, req.path); catch(Exception) {}
				onOpen(WSClient(client), req);
			}
		}
	}

	void handleFrame(WSClient client, Frame frame) {
		try
			tracef("From client %s received frame: done=%s; fin=%s; op=%s; length=%u",
				client.id, frame.done, frame.fin, frame.op, frame.length);
		catch (Exception) {}
		if (!frame.done)
			return;
		switch (frame.op) {
			case Op.CONT: return handleCont(client, frame);
			case Op.TEXT: return handle!false(client, frame);
			case Op.BINARY: return handle!true(client, frame);
			case Op.PING:
				enum pong = Frame(true, Op.PONG, false, State.done, [0, 0, 0, 0], 0, []).serialize;
				try
					client.send(pong);
				catch (Exception) {}
				return;
			case Op.PONG:
				try tracef("Received pong from %s", client.id); catch(Exception) {}
				return;
			default: return removeClient(client.id);
		}
	}

	import std.format;

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