module websocketd.server;

import std.socket;
import std.experimental.logger;

import websocketd.request;
import websocketd.frame;

alias PeerID = size_t;

class WebSocketState {
	Socket socket;
	bool handshaken;
	Frame[] frames;
	immutable PeerID id;
	immutable Address address;
	string path;
	string protocol; // subprotocol

	@disable this();

	this(PeerID id, Socket socket, string subprotocol = "") {
		this.socket = socket;
		this.id = id;
		this.address = cast(immutable Address)socket.remoteAddress;
		protocol = subprotocol;
	}

	void performHandshake(ubyte[] message) {
		import std.algorithm;
		import std.array;
		import std.base64 : Base64;
		import std.digest.sha : sha1Of;
		import std.datetime;
		import std.conv : to;

		assert(!handshaken);
		enum MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
			 KEY = "Sec-WebSocket-Key",
			 SUBP = "Sec-Websocket-Protocol";
		auto request = Request.parse(message);
		if (!request.done)
			return;
		auto key = KEY in request.headers;
		if (!key)
			return;
		path = request.path;

		auto accept = Base64.encode(sha1Of(*key ~ MAGIC));
		if (protocol.length) {
			if (auto subp = SUBP in request.headers) {
				auto arr = (*subp).split(',');
				if(!arr.canFind(protocol)) {
					protocol = "";
					return;
				}
			}
			accept ~= "\r\n" ~ SUBP ~ ": " ~ protocol;
		}
		assert(socket.isAlive);
		socket.send(
			"HTTP/1.1 101 Switching Protocol\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
			~ accept ~ "\r\n\r\n");
		socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(30));
		handshaken = true;
	}
}

abstract class WebSocketServer {
	import std.traits;

	protected WebSocketState[PeerID] sockets;
	private Socket listener;
	size_t maxConnections;

	abstract void onOpen(PeerID s, string path);
	abstract void onTextMessage(PeerID s, string s);
	abstract void onBinaryMessage(PeerID s, ubyte[] o);
	abstract void onClose(PeerID s);

	protected static PeerID counter = 0;

	this() { listener = new TcpSocket(); }

	private void add(Socket socket) {
		if (sockets.length >= maxConnections) {
			infof("Maximum number of connections reached (%u)", maxConnections);
			socket.close();
			return;
		}
		infof("Acception connection from %s (id=%u)", socket.remoteAddress, counter);
		sockets[counter] = new WebSocketState(counter, socket);
		counter++;
	}

	void remove(WebSocketState socket) {
		sockets.remove(socket.id);
		infof("Closing connection with client id %u", socket.id);
		if (socket.socket.isAlive)
			socket.socket.close();
		onClose(socket.id);
	}

	private void handle(WebSocketState socket, ubyte[] message) {
		import std.conv : to;
		import std.algorithm : swap;

		string processId = typeof(this).stringof ~ socket.id.to!string;
		if (socket.handshaken) {
			Frame prevFrame = processId.parse(message);
			Frame newFrame, temp;
			do {
				handleFrame(socket, prevFrame);
				newFrame = processId.parse([]);
				swap(newFrame, prevFrame);
			} while (newFrame != prevFrame);
		} else {
			socket.performHandshake(message);
			if (socket.handshaken)
				infof("Handshake with %d done (path=%s)", socket.id, socket.path);
			onOpen(socket.id, socket.path);
		}
	}

	private void handleFrame(WebSocketState socket, Frame frame) {
		tracef("From client %s received frame: done=%s; fin=%s; op=%s; length=%u",
			socket.id, frame.done, frame.fin, frame.op, frame.length);
		if (!frame.done)
			return;
		final switch (frame.op) {
			case Op.CONT: return handleCont(socket, frame);
			case Op.TEXT: return handleText(socket, frame);
			case Op.BINARY: return handleBinary(socket, frame);
			case Op.CLOSE: return remove(socket);
			case Op.PING:
				socket.socket.send(Frame(true, Op.PONG, false, 0, [0, 0, 0, 0], true, []).serialize);
				return;
			case Op.PONG: return tracef("Received pong from %s", socket.id);
		}
	}

	private void handleCont(WebSocketState socket, Frame frame)
	in (socket.frames.length > 0)
	{
		if (!frame.fin) {
			socket.frames ~= frame;
			return;
		}
		Op originalOp = socket.frames[0].op;
		ubyte[] data = [];
		for (size_t i = 0; i < socket.frames.length; i++)
			data ~= socket.frames[i].data;
		data ~= frame.data;
		socket.frames = [];
		if (originalOp == Op.TEXT)
			onTextMessage(socket.id, cast(string)data);
		else if (originalOp == Op.BINARY)
			onBinaryMessage(socket.id, data);
	}

	private void handleText(WebSocketState socket, Frame frame)
	in (socket.frames.length == 0)
	{
		if (frame.fin)
			onTextMessage(socket.id, cast(string)frame.data);
		else
			socket.frames ~= frame;
	}

	private void handleBinary(WebSocketState socket, Frame frame)
	in (socket.frames.length == 0)
	{
		if (frame.fin)
			onBinaryMessage(socket.id, frame.data);
		else
			socket.frames ~= frame;
	}

	public void send(T)(PeerID dest, T msg){
		auto dst = dest in sockets;
		if (!dst) {
			warningf("Tried to send a message to %s which is not connected", dest);
			return;
		}
		static if (isSomeString!T) {
			import std.string : representation;

			auto bytes = msg.representation;
			auto frame = Frame(true, Op.TEXT, false, msg.length, [0, 0, 0, 0], true, bytes.dup);
		} else {
			alias bytes = msg;
			auto frame = Frame(true, Op.BINARY, false, msg.length, [0, 0, 0, 0], true, msg);
		}
		auto data = frame.serialize;
		tracef("Sending %u bytes to %s in one frame of %u bytes long", bytes.length, dest, data.length);
		(*dst).socket.send(data);
	}

	public void run(ushort port, size_t maxConnections = 1000, size_t bufferSize = 1024)() {
		this.maxConnections = maxConnections;

		listener.blocking = false;
		listener.bind(new InternetAddress("127.0.0.1", port));
		listener.listen(10);

		infof("Listening on port: %u", port);
		infof("Maximum allowed connections: %u", maxConnections);

		auto set = new SocketSet(maxConnections + 1);
		for (;;) {
			set.add(listener);
			foreach (id, s; sockets)
				set.add(s.socket);
			Socket.select(set, null, null);

			foreach (id, socket; sockets) {
				if (!set.isSet(socket.socket))
					continue;
				ubyte[bufferSize] buffer;
				long receivedLength = socket.socket.receive(buffer[]);
				tracef("Received %u bytes from %s", receivedLength, socket.id);
				if (receivedLength > 0)
					handle(socket, buffer[0 .. receivedLength]);
				else
					remove(socket);
			}

			if (set.isSet(listener))
				add(listener.accept());

			set.reset();
		}
	}
}
