import std.experimental.logger;

import websocketd.server;

class EchoSocketServer : WebSocketServer {
	override void onOpen(PeerID s, string path) {
		tracef("Peer %s connect to '%s'", s, path);
	}

	override void onClose(PeerID s) {
	}

	override void onBinaryMessage(PeerID s, ubyte[] msg) {
	}

	override void onTextMessage(PeerID s, string msg) {
		tracef("Received message from %s", s);
		tracef("         message: %s", msg);
		tracef("         message length: %d", msg.length);
		send(s, msg);
	}

}

class BroadcastServer : WebSocketServer {
	private string[PeerID] peers;

	override void onOpen(PeerID s, string path) {
		peers[s] = path;
	}

	override void onClose(PeerID s) {
		peers.remove(s);
	}

	override void onTextMessage(PeerID src, string msg) {
		auto srcPath = peers[src];
		foreach (id, path; peers)
			if (id != src && path == srcPath)
				send(id, msg);
	}

	override void onBinaryMessage(PeerID src, ubyte[] msg) {
		auto srcPath = peers[src];
		foreach (id, path; peers)
			if (id != src && path == srcPath)
				send(id, msg);
	}
}

void main() {
	version(echo) {
		pragma(msg, "echo");
		WebSocketServer server = new EchoSocketServer();
	}
	version(broadcast) {
		pragma(msg, "broadcast");
		WebSocketServer server = new BroadcastServer();
	}

	server.run!(10301, 10);
}
