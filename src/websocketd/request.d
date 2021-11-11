module websocketd.request;

import std.ascii : isWhite;
import std.algorithm : endsWith;

struct Request {
	string method, path, httpVersion;
	string[string] headers;
	string message;
	bool done;

	static Request parse(ubyte[] bytes) {
		static ubyte[] data;
		static Request req = Request();

		data ~= bytes;
		auto msg = cast(string)data;
		if (!msg.endsWith("\r\n\r\n"))
			return req;

		size_t i = 0;
		string token;

		// get method
		for (; i < msg.length; i++) {
			if (msg[i] == ' ')
				break;
			token ~= msg[i];
		}
		i++; // skip whitespace
		req.method = token;
		token = "";

		// get path
		for (; i < msg.length; i++) {
			if (msg[i] == ' ')
				break;
			token ~= msg[i];
		}
		i++;
		req.path = token;
		token = "";

		// get version
		for (; i < msg.length; i++) {
			if (msg[i] == '\r')
				break;
			token ~= msg[i];
		}
		i++; // skip \r
		if (msg[i] != '\n')
			return req;
		i++;
		req.httpVersion = token;
		token = "";

		// get headers
		string key = "";
		for (; i < msg.length; i++) {
			token = "";
			key = "";
			if (msg[i] == '\r')
				break;
			for (; i < msg.length; i++) {
				if (msg[i] == ':' || msg[i].isWhite)
					break;
				token ~= msg[i];
			}
			i++;
			key = token;
			token = "";
			for (; i < msg.length; i++)
				if (!msg[i].isWhite)
					break; // ignore whitespace
			for (; i < msg.length; i++) {
				if (msg[i] == '\r')
					break;
				token ~= msg[i];
			}
			i++;
			if (msg[i] != '\n')
				return req;
			req.headers[key] = token;
		}

		i++;
		if (msg[i] != '\n')
			return req;
		i++;

		req.message = msg[i .. $];
		req.done = true;
		Request ans = req;
		req = Request();
		data = [];
		return ans;
	}
}
