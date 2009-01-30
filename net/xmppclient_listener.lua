-- Prosody IM v0.2
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local logger = require "logger";
local lxp = require "lxp"
local init_xmlhandlers = require "core.xmlhandlers"
local sm_new_session = require "core.sessionmanager".new_session;

local connlisteners_register = require "net.connlisteners".register;

local t_insert = table.insert;
local t_concat = table.concat;
local t_concatall = function (t, sep) local tt = {}; for _, s in ipairs(t) do t_insert(tt, tostring(s)); end return t_concat(tt, sep); end
local m_random = math.random;
local format = string.format;
local sm_new_session, sm_destroy_session = sessionmanager.new_session, sessionmanager.destroy_session; --import("core.sessionmanager", "new_session", "destroy_session");
local sm_streamopened = sessionmanager.streamopened;
local sm_streamclosed = sessionmanager.streamclosed;
local st = stanza;

local stream_callbacks = { stream_tag = "http://etherx.jabber.org/streams|stream", streamopened = sm_streamopened, streamclosed = sm_streamclosed, handlestanza = core_process_stanza };

function stream_callbacks.error(session, error, data)
	if error == "no-stream" then
		session:close("invalid-namespace");
	else
		session.log("debug", "Client XML parse error: %s", tostring(error));
		session:close("xml-not-well-formed");
	end
end

local function handleerr(err) log("error", "Traceback[c2s]: %s: %s", tostring(err), debug.traceback()); end
function stream_callbacks.handlestanza(a, b)
	xpcall(function () core_process_stanza(a, b) end, handleerr);
end

local sessions = {};
local xmppclient = { default_port = 5222, default_mode = "*a" };

-- These are session methods --

local function session_reset_stream(session)
	-- Reset stream
		local parser = lxp.new(init_xmlhandlers(session, stream_callbacks), "|");
		session.parser = parser;
		
		session.notopen = true;
		
		function session.data(conn, data)
			local ok, err = parser:parse(data);
			if ok then return; end
			session:close("xml-not-well-formed");
		end
		
		return true;
end


local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local function session_close(session, reason)
	local log = session.log or log;
	if session.conn then
		if reason then
			if type(reason) == "string" then -- assume stream error
				log("info", "Disconnecting client, <stream:error> is: %s", reason);
				session.send(st.stanza("stream:error"):tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' }));
			elseif type(reason) == "table" then
				if reason.condition then
					local stanza = st.stanza("stream:error"):tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stanza:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stanza:add_child(reason.extra);
					end
					log("info", "Disconnecting client, <stream:error> is: %s", tostring(stanza));
					session.send(stanza);
				elseif reason.name then -- a stanza
					log("info", "Disconnecting client, <stream:error> is: %s", tostring(reason));
					session.send(reason);
				end
			end
		end
		session.send("</stream:stream>");
		session.conn.close();
		xmppclient.disconnect(session.conn, "stream error");
	end
end


-- End of session methods --

function xmppclient.listener(conn, data)
	local session = sessions[conn];
	if not session then
		session = sm_new_session(conn);
		sessions[conn] = session;

		-- Logging functions --

		local conn_name = "c2s"..tostring(conn):match("[a-f0-9]+$");
		session.log = logger.init(conn_name);
		
		session.log("info", "Client connected");
		
		session.reset_stream = session_reset_stream;
		session.close = session_close;
		
		session_reset_stream(session); -- Initialise, ready for use
		
		session.dispatch_stanza = stream_callbacks.handlestanza;
	end
	if data then
		session.data(conn, data);
	end
end
	
function xmppclient.disconnect(conn, err)
	local session = sessions[conn];
	if session then
		(session.log or log)("info", "Client disconnected: %s", err);
		sm_destroy_session(session);
		sessions[conn]  = nil;
		session = nil;
		collectgarbage("collect");
	end
end

connlisteners_register("xmppclient", xmppclient);
