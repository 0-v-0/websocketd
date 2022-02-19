module websocketd.request;

import std.ascii : isWhite;
import std.algorithm : endsWith;
import std.uni : toLower;

struct Request {
	string method, path, httpVersion;
	string[string] headers;
	string message;
	bool done;

	static Request parse(in ubyte[] bytes) nothrow {
		static ubyte[] data;
		static Request req;

		data ~= bytes;
		auto msg = cast(string)data;
		if (!msg.endsWith("\r\n\r\n"))
			return req;

		size_t i = 0, pos;

		// get method
		for (; i < msg.length; i++)
			if (msg[i] == ' ')
				break;

		req.method = msg[0..i];
		pos = ++i; // skip whitespace

		// get path
		for (; i < msg.length; i++)
			if (msg[i] == ' ')
				break;

		req.path = msg[pos..i];
		pos = ++i;

		// get version
		for (; i < msg.length; i++)
			if (msg[i] == '\r')
				break;

		i++; // skip \r
		if (msg[i] != '\n')
			return req;
		req.httpVersion = msg[pos..i-1];
		pos = i++;

		// get headers
		string key;
		for (; i < msg.length; i++) {
			if (msg[i] == '\r')
				break;
			pos = i;
			for (; i < msg.length; i++)
				if (msg[i] == ':' || msg[i].isWhite)
					break;

			key = msg[pos..i];
			i++;
			for (; i < msg.length; i++)
				if (!msg[i].isWhite)
					break; // ignore whitespace
			pos = i;
			for (; i < msg.length; i++)
				if (msg[i] == '\r')
					break;

			i++;
			if (msg[i] != '\n')
				return req;
			try
				req.headers[key.toLower] = msg[pos..i-1];
			catch(Exception) {}
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
