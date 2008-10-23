
-- The code in this file should be self-explanatory, though the logic is horrible
-- for more info on that, see doc/stanza_routing.txt, which attempts to condense
-- the rules from the RFCs (mainly 3921)

require "core.servermanager"

local log = require "util.logger".init("stanzarouter")

local st = require "util.stanza";
local send = require "core.sessionmanager".send_to_session;
local user_exists = require "core.usermanager".user_exists;

local jid_split = require "util.jid".split;
local print = print;

function core_process_stanza(origin, stanza)
	log("debug", "Received: "..tostring(stanza))
	-- TODO verify validity of stanza (as well as JID validity)
	if stanza.name == "iq" and not(#stanza.tags == 1 and stanza.tags[1].attr.xmlns) then
		if stanza.attr.type == "set" or stanza.attr.type == "get" then
			error("Invalid IQ");
		elseif #stanza.tags > 1 or not(stanza.attr.type == "error" or stanza.attr.type == "result") then
			error("Invalid IQ");
		end
	end

	if origin.type == "c2s" and not origin.full_jid
		and not(stanza.name == "iq" and stanza.tags[1].name == "bind"
				and stanza.tags[1].attr.xmlns == "urn:ietf:params:xml:ns:xmpp-bind") then
		error("Client MUST bind resource after auth");
	end

	local to = stanza.attr.to;
	stanza.attr.from = origin.full_jid; -- quick fix to prevent impersonation (FIXME this would be incorrect when the origin is not c2s)
	-- TODO also, stazas should be returned to their original state before the function ends
	
	-- TODO presence subscriptions
	if not to then
			core_handle_stanza(origin, stanza);
	elseif hosts[to] and hosts[to].type == "local" then
		core_handle_stanza(origin, stanza);
	elseif stanza.name == "iq" and not select(3, jid_split(to)) then
		core_handle_stanza(origin, stanza);
	elseif origin.type == "c2s" then
		core_route_stanza(origin, stanza);
	end
end

function core_handle_stanza(origin, stanza)
	-- Handlers
	if origin.type == "c2s" or origin.type == "c2s_unauthed" then
		local session = origin;
		
		if stanza.name == "presence" and origin.roster then
			if stanza.attr.type == nil or stanza.attr.type == "available" or stanza.attr.type == "unavailable" then
				for jid in pairs(origin.roster) do -- broadcast to all interested contacts
					local subscription = origin.roster[jid].subscription;
					if subscription == "both" or subscription == "from" then
						stanza.attr.to = jid;
						core_route_stanza(origin, stanza);
					end
				end
				--[[local node, host = jid_split(stanza.attr.from);
				for _, res in pairs(hosts[host].sessions[node].sessions) do -- broadcast to all resources
					if res.full_jid then
						res = user.sessions[k];
						break;
					end
				end]]
				if not origin.presence then -- presence probes on initial presence
					local probe = st.presence({from = origin.full_jid, type = "probe"});
					for jid in pairs(origin.roster) do
						local subscription = origin.roster[jid].subscription;
						if subscription == "both" or subscription == "to" then
							probe.attr.to = jid;
							core_route_stanza(origin, probe);
						end
					end
				end
				origin.presence = stanza;
				stanza.attr.to = nil; -- reset it
			else
				-- TODO error, bad type
			end
		else
			log("debug", "Routing stanza to local");
			handle_stanza(session, stanza);
		end
	end
end

function is_authorized_to_see_presence(origin, username, host)
	local roster = datamanager.load(username, host, "roster") or {};
	local item = roster[origin.username.."@"..origin.host];
	return item and (item.subscription == "both" or item.subscription == "from");
end

function core_route_stanza(origin, stanza)
	-- Hooks
	--- ...later
	
	-- Deliver
	local to = stanza.attr.to;
	local node, host, resource = jid_split(to);

	if stanza.name == "presence" and stanza.attr.type == "probe" then resource = nil; end

	local host_session = hosts[host]
	if host_session and host_session.type == "local" then
		-- Local host
		local user = host_session.sessions[node];
		if user then
			local res = user.sessions[resource];
			if not res then
				-- if we get here, resource was not specified or was unavailable
				if stanza.name == "presence" then
					if stanza.attr.type == "probe" then
						if is_authorized_to_see_presence(origin, node, host) then
							for k in pairs(user.sessions) do -- return presence for all resources
								if user.sessions[k].presence then
									local pres = user.sessions[k].presence;
									pres.attr.to = origin.full_jid;
									pres.attr.from = user.sessions[k].full_jid;
									send(origin, pres);
									pres.attr.to = nil;
									pres.attr.from = nil;
								end
							end
						else
							send(origin, st.presence({from = user.."@"..host, to = origin.username.."@"..origin.host, type = "unsubscribed"}));
						end
					else
						for k in pairs(user.sessions) do -- presence broadcast to all user resources
							if user.sessions[k].full_jid then
								stanza.attr.to = user.sessions[k].full_jid;
								send(user.sessions[k], stanza);
							end
						end
					end
				elseif stanza.name == "message" then -- select a resource to recieve message
					for k in pairs(user.sessions) do
						if user.sessions[k].full_jid then
							res = user.sessions[k];
							break;
						end
					end
					-- TODO find resource with greatest priority
					send(res, stanza);
				else
					-- TODO send IQ error
				end
			else
				stanza.attr.to = res.full_jid;
				send(res, stanza); -- Yay \o/
			end
		else
			-- user not online
			if user_exists(node, host) then
				if stanza.name == "presence" then
					if stanza.attr.type == "probe" and is_authorized_to_see_presence(origin, node, host) then -- FIXME what to do for not c2s?
						-- TODO send last recieved unavailable presence
					else
						-- TODO send unavailable presence
					end
				elseif stanza.name == "message" then
					-- TODO send message error, or store offline messages
				elseif stanza.name == "iq" then
					-- TODO send IQ error
				end
			else -- user does not exist
				-- TODO we would get here for nodeless JIDs too. Do something fun maybe? Echo service? Let plugins use xmpp:server/resource addresses?
				if stanza.name == "presence" then
					if stanza.attr.type == "probe" then
						send(origin, st.presence({from = user.."@"..host, to = origin.username.."@"..origin.host, type = "unsubscribed"}));
					end
					-- else ignore
				else
					send(origin, st.error_reply(stanza, "cancel", "service-unavailable"));
				end
			end
		end
	else
		-- Remote host
		if host_session then
			-- Send to session
		else
			-- Need to establish the connection
		end
	end
	stanza.attr.to = to; -- reset
end

function handle_stanza_nodest(stanza)
	if stanza.name == "iq" then
		handle_stanza_iq_no_to(session, stanza);
	elseif stanza.name == "presence" then
		-- Broadcast to this user's contacts
		handle_stanza_presence_broadcast(session, stanza);
		-- also, if it is initial presence, send out presence probes
		if not session.last_presence then
			handle_stanza_presence_probe_broadcast(session, stanza);
		end
		session.last_presence = stanza;
	elseif stanza.name == "message" then
		-- Treat as if message was sent to bare JID of the sender
		handle_stanza_to_local_user(stanza);
	end
end

function handle_stanza_tolocal(stanza)
	local node, host, resource = jid.split(stanza.attr.to);
	if host and hosts[host] and hosts[host].type == "local" then
			-- Is a local host, handle internally
			if node then
				-- Is a local user, send to their session
				log("debug", "Routing stanza to %s@%s", node, host);
				if not session.username then return; end --FIXME: Correct response when trying to use unauthed stream is what?
				handle_stanza_to_local_user(stanza);
			else
				-- Is sent to this server, let's handle it...
				log("debug", "Routing stanza to %s", host);
				handle_stanza_to_server(stanza, session);
			end
	end
end

function handle_stanza_toremote(stanza)
	log("error", "Stanza bound for remote host, but s2s is not implemented");
end


--[[
local function route_c2s_stanza(session, stanza)
	stanza.attr.from = session.full_jid;
	if not stanza.attr.to and session.username then
		-- Has no 'to' attribute, handle internally
		if stanza.name == "iq" then
			handle_stanza_iq_no_to(session, stanza);
		elseif stanza.name == "presence" then
			-- Broadcast to this user's contacts
			handle_stanza_presence_broadcast(session, stanza);
			-- also, if it is initial presence, send out presence probes
			if not session.last_presence then
				handle_stanza_presence_probe_broadcast(session, stanza);
			end
			session.last_presence = stanza;
		elseif stanza.name == "message" then
			-- Treat as if message was sent to bare JID of the sender
			handle_stanza_to_local_user(stanza);
		end
	end
	local node, host, resource = jid.split(stanza.attr.to);
	if host and hosts[host] and hosts[host].type == "local" then
			-- Is a local host, handle internally
			if node then
				-- Is a local user, send to their session
				if not session.username then return; end --FIXME: Correct response when trying to use unauthed stream is what?
				handle_stanza_to_local_user(stanza);
			else
				-- Is sent to this server, let's handle it...
				handle_stanza_to_server(stanza, session);
			end
	else
		-- Is not for us or a local user, route accordingly
		route_s2s_stanza(stanza);
	end
end

function handle_stanza_no_to(session, stanza)
	if not stanza.attr.id then log("warn", "<iq> without id attribute is invalid"); end
	local xmlns = (stanza.tags[1].attr and stanza.tags[1].attr.xmlns);
	if stanza.attr.type == "get" or stanza.attr.type == "set" then
		if iq_handlers[xmlns] then
			if iq_handlers[xmlns](stanza) then return; end; -- If handler returns true, it handled it
		end
		-- Oh, handler didn't handle it. Need to send service-unavailable now.
		log("warn", "Unhandled namespace: "..xmlns);
		session:send(format("<iq type='error' id='%s'><error type='cancel'><service-unavailable/></error></iq>", stanza.attr.id));
		return; -- All done!
	end
end

function handle_stanza_to_local_user(stanza)
	if stanza.name == "message" then
		handle_stanza_message_to_local_user(stanza);
	elseif stanza.name == "presence" then
		handle_stanza_presence_to_local_user(stanza);
	elseif stanza.name == "iq" then
		handle_stanza_iq_to_local_user(stanza);
	end
end

function handle_stanza_message_to_local_user(stanza)
	local node, host, resource = stanza.to.node, stanza.to.host, stanza.to.resource;
	local destuser = hosts[host].sessions[node];
	if destuser then
		if resource and destuser[resource] then
			destuser[resource]:send(stanza);
		else
			-- Bare JID, or resource offline
			local best_session;
			for resource, session in pairs(destuser.sessions) do
				if not best_session then best_session = session;
				elseif session.priority >= best_session.priority and session.priority >= 0 then
					best_session = session;
				end
			end
			if not best_session then
				offlinemessage.new(node, host, stanza);
			else
				print("resource '"..resource.."' was not online, have chosen to send to '"..best_session.username.."@"..best_session.host.."/"..best_session.resource.."'");
				destuser[best_session]:send(stanza);
			end
		end
	else
		-- User is offline
		offlinemessage.new(node, host, stanza);
	end
end

function handle_stanza_presence_to_local_user(stanza)
	local node, host, resource = stanza.to.node, stanza.to.host, stanza.to.resource;
	local destuser = hosts[host].sessions[node];
	if destuser then
		if resource then
			if destuser[resource] then
				destuser[resource]:send(stanza);
			else
				return;
			end
		else
			-- Broadcast to all user's resources
			for resource, session in pairs(destuser.sessions) do
				session:send(stanza);
			end
		end
	end
end

function handle_stanza_iq_to_local_user(stanza)

end

function foo()
		local node, host, resource = stanza.to.node, stanza.to.host, stanza.to.resource;
		local destuser = hosts[host].sessions[node];
		if destuser and destuser.sessions then
			-- User online
			if resource and destuser.sessions[resource] then
				stanza.to:send(stanza);
			else
				--User is online, but specified resource isn't (or no resource specified)
				local best_session;
				for resource, session in pairs(destuser.sessions) do
					if not best_session then best_session = session;
					elseif session.priority >= best_session.priority and session.priority >= 0 then
						best_session = session;
					end
				end
				if not best_session then
					offlinemessage.new(node, host, stanza);
				else
					print("resource '"..resource.."' was not online, have chosen to send to '"..best_session.username.."@"..best_session.host.."/"..best_session.resource.."'");
					resource = best_session.resource;
				end
			end
			if destuser.sessions[resource] == session then
				log("warn", "core", "Attempt to send stanza to self, dropping...");
			else
				print("...sending...", tostring(stanza));
				--destuser.sessions[resource].conn.write(tostring(data));
				print("   to conn ", destuser.sessions[resource].conn);
				destuser.sessions[resource].conn.write(tostring(stanza));
				print("...sent")
			end
		elseif stanza.name == "message" then
			print("   ...will be stored offline");
			offlinemessage.new(node, host, stanza);
		elseif stanza.name == "iq" then
			print("   ...is an iq");
			stanza.from:send(st.reply(stanza)
				:tag("error", { type = "cancel" })
					:tag("service-unavailable", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" }));
		end
end

-- Broadcast a presence stanza to all of a user's contacts
function handle_stanza_presence_broadcast(session, stanza)
	if session.roster then
		local initial_presence = not session.last_presence;
		session.last_presence = stanza;
		
		-- Broadcast presence and probes
		local broadcast = st.presence({ from = session.full_jid, type = stanza.attr.type });

		for child in stanza:childtags() do
			broadcast:add_child(child);
		end
		for contact_jid in pairs(session.roster) do
			broadcast.attr.to = contact_jid;
			send_to(contact_jid, broadcast);
			if initial_presence then
				local node, host = jid.split(contact_jid);
				if hosts[host] and hosts[host].type == "local" then
					local contact = hosts[host].sessions[node]
					if contact then
						local pres = st.presence { to = session.full_jid };
						for resource, contact_session in pairs(contact.sessions) do
							if contact_session.last_presence then
								pres.tags = contact_session.last_presence.tags;
								pres.attr.from = contact_session.full_jid;
								send(pres);
							end
						end
					end
					--FIXME: Do we send unavailable if they are offline?
				else
					probe.attr.to = contact;
					send_to(contact, probe);
				end
			end
		end
		
		-- Probe for our contacts' presence
	end
end

-- Broadcast presence probes to all of a user's contacts
function handle_stanza_presence_probe_broadcast(session, stanza)
end

-- 
function handle_stanza_to_server(stanza)
end

function handle_stanza_iq_no_to(session, stanza)
end
]]