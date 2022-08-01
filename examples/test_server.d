import std.experimental.logger;

import websocketd;

class EchoSocketServer : WSServer {
	override void onOpen(WSClient client, Request req) {
		try
			tracef("Peer %s connect to '%s'", client.id, req.path);
		catch (Exception) {
		}
	}

	override void onTextMessage(WSClient client, string msg) {
		try {
			client.send(msg);
		} catch (Exception) {
		}
	}
}

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
		try {
			foreach (id, path; peers)
				if (id != src && path == srcPath)
					clients[id].send(msg);
		} catch (Exception) {
		}
	}

	override void onBinaryMessage(WSClient client, ubyte[] msg) {
		auto src = client.id;
		auto srcPath = peers[src];
		try
			foreach (id, path; peers)
				if (id != src && path == srcPath)
					send(clients[id], msg);
					catch (Exception) {
					}
	}
}

void main() {
	version (echo) {
		pragma(msg, "echo");
		auto server = new EchoSocketServer;
	}
	version (broadcast) {
		pragma(msg, "broadcast");
		auto server = new BroadcastServer;
	}

	server.run(10301);
}
