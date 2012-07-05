--Copyright (c) 2012 Matthias Richter
--
--Permission is hereby granted, free of charge, to any person obtaining a copy of
--this software and associated documentation files (the "Software"), to deal in
--the Software without restriction, including without limitation the rights to
--use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
--of the Software, and to permit persons to whom the Software is furnished to do
--so, subject to the following conditions:
--
--The above copyright notice and this permission notice shall be included in all
--copies or substantial portions of the Software.
--
--Except as contained in this notice, the name(s) of the above copyright holders
--shall not be used in advertising or otherwise to promote the sale, use or
--other dealings in this Software without prior written authorization.
--
--If you find yourself in a situation where you can safe the author's life
--without risking your own safety, you are obliged to do so.
--
--THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
--OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
--SOFTWARE.

local socket = require 'socket'

-- helper
local function Set(t)
	local s = {}
	for _,v in ipairs(t) do s[v] = true end
	return s
end

do -- augment assert to use format strings
	local _assert = assert
	local function assert(arg, str, ...)
		_assert(arg, str:format(...))
	end
end

-- argument checkers.
-- e.g.: assert_arg(1, foo).type('string', 'number')
--       assert_arg(2, bar).any('one', 2, true)
local function assert_arg(n,v)
	return {
		type = function(...)
			local s = type(v)
			for t in pairs(Set{...}) do if s == t then return end end
			local t = table.concat({...}, "' or `")
			error(("Error in argument %s: Expected `%s', got `%s'"):format(n, t, s), 2)
		end,
		any = function(...)
			for u in pairs(Set{...}) do if u == v then return end end
			local u = table.concat({...}, "', `")
			error(("Error in argument %s: Expected to be one of (`%s'), got `%s'"):format(n, u, tostring(v)), 2)
		end
	}
end

-- generates tokens for IMAP conversations
local function token_generator()
	local prefix = math.random()
	local n = 0
	return function()
		n = n + 1
		return prefix .. n
	end
end

-- (nested) table to IMAP lists. table may not contain loops
local function to_list(tbl)
	if type(tbl) == 'table' then
		local s = {}
		for k,v in ipairs(tbl) do s[k] = to_list(v) end
		return '(' .. table.concat(s, ' ') .. ')'
	end
	return tbl
end

-- poor mans s-expressions:
-- make a table out of an IMAP list
local function to_table(list)
	local token = coroutine.wrap(function()
		for c in list:gmatch('.') do coroutine.yield(c) end
		coroutine.yield(nil)
	end)

	local stack, cur = {}, {}
	local atom = {}
	local function finish_atom()
		if #atom > 0 then
			cur[#cur+1] = table.concat(atom)
			atom = {}
		end
	end

	while true do
		local t = token()
		if not t then
			error([[Malformated reply: Unexpected end of string]])
		elseif t == '(' then
			-- push table
			stack[#stack+1] = {}
			cur = stack[#stack]
		elseif t == ')' then
			finish_atom()
			-- pop table
			stack[#stack] = nil
			local t = cur
			cur = stack[#stack]
			if not cur then return t end
			cur[#cur+1] = t
		elseif t == '[' then
			-- hack-ish: [] quotes lists
			atom[#atom+1] = t
			repeat
				atom[#atom+1] = assert(token(), [[Malformated reply: Unmatched `[']])
			until atom[#atom] == ']'
		elseif t == '"' then
			-- add string
			local chars = {}
			repeat
				chars[#chars+1] = assert(token(), [[Malformated reply: Unfinished string]])
			until chars[#chars-1] ~= '\\' and chars[#chars] == '"'
			chars[#chars] = nil
			cur[#cur+1] = table.concat(chars)
		elseif t == '{' then
			-- add literal
			local n = {}
			repeat
				n[#n+1] = assert(token(), [[Malformated reply: Unfinished literal prelude]])
			until n[#n] == '}'
			n[#n] = nil
			n = tostring(table.concat(n))

			assert(token() == '\r' and token() == '\n', [[Malformated reply: Invalid literal]])
			local chars = {}
			for i = 1,n do
				chars[i] = assert(token(), [[Malformated reply: Unfinished literal]])
			end
			cur[#cur+1] = table.concat(chars)
		elseif t:match('%s') then
			finish_atom()
		else
			atom[#atom+1] = t
		end
	end
end

-- valid commands given a state
local commands_allowed = {
	capability   = Set{'not-authenticated', 'authenticated', 'selected'},
	noop         = Set{'not-authenticated', 'authenticated', 'selected'},
	logout       = Set{'not-authenticated', 'authenticated', 'selected'},
	starttls     = Set{'not-Authenticated'},
	authenticate = Set{'not-Authenticated'},
	login        = Set{'not-Authenticated'},
	select       = Set{'authenticated', 'selected'},
	examine      = Set{'authenticated', 'selected'},
	create       = Set{'authenticated', 'selected'},
	delete       = Set{'authenticated', 'selected'},
	rename       = Set{'authenticated', 'selected'},
	subscribe    = Set{'authenticated', 'selected'},
	unsubscribe  = Set{'authenticated', 'selected'},
	list         = Set{'authenticated', 'selected'},
	lsub         = Set{'authenticated', 'selected'},
	status       = Set{'authenticated', 'selected'},
	append       = Set{'authenticated', 'selected'},
	check        = Set{'selected'},
	close        = Set{'selected'},
	expunge      = Set{'selected'},
	search       = Set{'selected'},
	fetch        = Set{'selected'},
	store        = Set{'selected'},
	copy         = Set{'selected'},
	uid          = Set{'selected'},
}

-- imap4 connection
local IMAP = {}

-- checks if command is valid in current state
function IMAP.__index(self, k)
	local states = commands_allowed[self]
	if states then
		assert(states[self.state], "Command `%s' not allowed in state `%s'.", k, self.state)
	end
	return rawget(IMAP, k)
end

-- constructor
function IMAP.new(host, port)
	assert_arg(1, host).type('string')
	assert_arg(2, port).type('number', 'nil')

	port = port or 143
	local s = assert(socket.connect(host, port), "Cannot connect to %s:%u", host, port)
	s:settimeout(5)

	local imap = setmetatable({
		host       = host,
		port       = port,
		socket     = s,
		next_token = token_generator(),
		state      = 'not-authenticated'
	}, IMAP)

	local greeting = imap:_get_line():match("^%*%s+(.*)")
	if not greeting then
		self.socket:close()
		assert(nil, "Did not receive greeting from %s:%u", host, port)
	end

	return imap, greeting
end

-- gets a full line from the socket. may block
function IMAP:_get_line()
	local line = {}
	repeat
		local res, errstate, partial = self.socket:receive('*l')
		if not res then
			assert(errstate ~= 'closed', 'Connection to %s:%u closed unexpectedly', self.host, self.port)
			assert(#partial > 0, 'Connection to %s:%u timed out', self.host, self.port)
			line[#line+1] = partial
		end
		line[#line+1] = res -- does nothing if res is nil
	until res
	return table.concat(line)
end

-- Transforms lines into response tables
local function transform_result(lines)
	-- merge lines into response blocks
	local blocks = {}
	for _, line in ipairs(lines) do
		local firstchar = line:sub(1,1)
		if firstchar == '*' then
			blocks[#blocks+1] = line:sub(3)
		elseif firstchar ~= '+' then
			blocks[#blocks] = blocks[#blocks] .. '\r\n' .. line
		end -- ignore continue request
	end

	-- transform blocks into response table of the format:
	-- res = {
	--    TOKEN1 = {a, b, ...},
	--    TOKEN2 = {x, y, ...},
	--    ...
	-- }
	local res = setmetatable({}, {__index = function(t,k)
		local s = {}
		rawset(t,k,s)
		return s
	end})
	for _, b in ipairs(blocks) do
		local token, args = b:match('^(%S+) (.*)$')
		-- whoever thought 'number SP token' was a good idea should be first
		-- to be placed against the wall when the revolution comes
		if tonumber(token) ~= nil then
			local n = token
			token, args = args:match('^(%S+)%s*(.*)$')
			args = table.concat({n,args}, ' ')
		end
		local t = res[token]
		t[#t+1] = args
	end
	return res
end

-- invokes a tagged command and returns response blocks
function IMAP:_do_cmd(cmd, ...)
	--assert(self.socket, 'Connection closed')
	local token = self:next_token()

	-- send request
	local data  = token .. ' ' .. cmd:format(...) .. '\r\n'
	local len   = assert(self.socket:send(data))
	assert(len == #data, 'Broken connection: Could not send all required data')

	-- receive answer line by line (unparsed)
	local lines = {}
	while true do
		local line = self:_get_line()

		-- return if there was a tagged response
		local status, msg = line:match('^'..token..' ([A-Z]+) (.*)$')
		if status == 'OK' then
			return transform_result(lines)
		elseif status == 'NO' or status == 'BAD' then
			error(("Command `%s' failed: %s"):format(cmd, msg), 3)
		end

		lines[#lines+1] = line
	end
end

-- any state

-- returns table with server capabilities
function IMAP:capability()
	local cap = {}
	local res = self:_do_cmd('CAPABILITY')
	for w in table.concat(res.CAPABILITY, ' '):gmatch('%S+') do
		cap[#cap+1] = w
		cap[w] = true
	end
	return cap, res
end

-- test if server is capable of *all* listed arguments
function IMAP:isCapable(...)
	local cap = self:capability()
	for _,v in ipairs{...} do
		if not cap[v] then return false end
	end
	return true
end

-- does nothing, but may receive updated state
function IMAP:noop()
	return self:_do_cmd('NOOP')
end

function IMAP:logout()
	local res = self:_do_cmd('LOGOUT')
	self.socket:close()
	return res
end

-- start TLS connection. requires luasec. see luasec documentation for
-- infos on what tls_params should be.
function IMAP:starttls(tls_params)
	assert_arg(1, tls_params).type('table')
	assert(self:isCapable('STARTTLS'))
	local res = self:_do_cmd('STARTTLS')
	local ssl = require 'ssl'
	self.socket = ssl.wrap(self.socket, tls_params)
	self.socket:dohandshake()
	return res
end

function IMAP:authenticate()
	error('Not implemented')
end

-- plain text login. do not use unless connection is secure (i.e. TLS or SSH tunnel)
function IMAP:login(user, pass)
	local res = self:_do_cmd('LOGIN %s %s', user, pass)
	self.state = 'authenticated'
	return res
end

-- authenticated state
-- select and examine get the same results
local function parse_select_examine(res)
	return {
		flags = to_table(res.FLAGS[1] or "()"),
		exist = tonumber(res.EXISTS[1]),
		recent = tonumber(res.RECENT[1])
	}
end

-- select a mailbox so that messages in the mailbox can be accessed
-- returns a table of the following format:
-- { flags = {string...}, exist = number, recent = number}
function IMAP:select(mailbox)
	-- if this fails we go back to authenticated state
	if self.state == 'selected' then self.state = 'authenticated' end
	local res = self:_do_cmd('SELECT %s', mailbox)
	self.state = 'selected'
	return parse_select_examine(res), res
end

-- same as IMAP:select, except that the mailbox is set to read-only
function IMAP:examine(mailbox)
	if self.state == 'selected' then self.state = 'authenticated' end
	local res = self:_do_cmd('SELECT %s', mailbox)
	self.state = 'selected'
	return parse_select_examine(res), res
end

-- create a new mailbox
function IMAP:create(mailbox)
	return self:_do_cmd('CREATE %s', mailbox)
end

-- delete an existing mailbox
function IMAP:delete(mailbox)
	return self:_do_cmd('DELETE %s', mailbox)
end

-- renames a mailbox
function IMAP:rename(from, to)
	return self:_do_cmd('RENAME %s %s', from, to)
end

-- marks mailbox as subscribed
-- subscribed mailboxes will be listed with the lsub command
function IMAP:subscribe(mailbox)
	return self:_do_cmd('SUBSCRIBE %s', mailbox)
end

-- unsubscribe a mailbox
function IMAP:unsubscribe(mailbox)
	return self:_do_cmd('UNSUBSCRIBE %s', mailbox)
end

-- parse response from IMAP:list() and IMAP:lsub()
local function parse_list_lsub(res, token)
	local mailboxes = {}
	for _,r in ipairs(res[token]) do
		local flags, delim, name = r:match('^(%b()) (%b"") (.+)$')
		flags = to_table(flags)

		if name:sub(1,1) == '"' and name:sub(-1) == '"' then
			name = name:sub(2,-2)
		end
		mailboxes[name] = {delim = delim:sub(2,-2), flags = flags}
	end
	return mailboxes
end

-- list mailboxes, where `mailbox' is a mailbox name with possible 
-- wildcards and `ref' is a reference name. Default parameters are:
-- mailbox = '*' (match all) and ref = '""' (no reference name)
-- See RFC3501 Sec 6.3.8 for details.
function IMAP:list(mailbox, ref)
	mailbox = mailbox or '*'
	ref = ref or '""'
	local res = self:_do_cmd('LIST %s %s', ref, mailbox)
	return parse_list_lsub(res, 'LIST'), res
end

-- same as IMAP:list(), but lists only subscribed or active mailboxes.
function IMAP:lsub(mailbox, ref)
	mailbox = mailbox or "*"
	ref = ref or '""'
	local res = self:_do_cmd('LSUB %s %s', ref, mailbox)
	return parse_list_lsub(res, 'LSUB'), res
end

-- get mailbox information. `status' may be a string or a table of strings
-- as defined by RFC3501 Sec 6.3.10:
-- MESSAGES, RECENT, UIDNEXT, UIDVALIDITY and UNSEEN
function IMAP:status(mailbox, names)
	assert_arg(1, mailbox).type('string')
	assert_arg(2, names).type('string', 'table', 'nil')

	names = to_list(names or '(MESSAGES RECENT UIDNEXT UIDVALIDITY UNSEEN)')
	local res = self:_do_cmd('STATUS %s %s', mailbox, names)

	local list = to_table(assert(res.STATUS[1]:match('(%b())$'), 'Invalid response'))
	assert(#list % 2 == 0, "Invalid response size")

	local status = {}
	for i = 1,#list,2 do
		status[list[i]] = tonumber(list[i+1])
	end
	return status, res
end

-- append a message to a mailbox
function IMAP:append(mailbox, message, flags, date)
	assert_arg(1, mailbox).type('string')
	assert_arg(2, message).type('string')
	assert_arg(3, flags).type('table', 'nil')
	assert_arg(4, date).type('string', 'nil')

	message = ('{%d}\r\n%s'):format(#message, message) -- message literal
	flags = flags and ' ' .. to_list(flags) or ''
	date = date and ' ' .. date or ''

	return self:_do_cmd('APPEND %s%s%s %s', mailbox, flags, date, message)
end

-- requests a checkpoint of the currently selected mailbox
function IMAP:check()
	return self:_do_cmd('CHECK')
end

-- permanently removes all messages with \Deleted flag from currently
-- selected mailbox without giving responses. return to
-- 'authenticated' state.
function IMAP:close()
	local res = self:_do_cmd('CLOSE')
	self.state = 'authenticated'
	return res
end

-- permanently removes all messages with \Deleted flag from currently
-- selected mailbox. returns a table of deleted message numbers/ids.
function IMAP:expunge()
	local res = self:_do_cmd('EXPUNGE')
	return res.EXPUNGE, res
end

-- searches the mailbox for messages that match the given searching criteria
-- See RFC3501 Sec 6.4.4 for details
function IMAP:search(criteria, charset, uid)
	assert_arg(1, criteria).type('string', 'table')
	assert_arg(2, charset).type('string', 'nil')

	charset = charset and 'CHARSET ' .. charset or ''
	criteria = to_list(criteria)
	uid = uid and 'UID ' or ''

	local res = self:_do_cmd('%sSEARCH %s %s', uid, charset, criteria)
	local ids = {}
	for id in res.SEARCH[1]:gmatch('%S+') do
		ids[#ids+1] = tonumber(id)
	end
	return ids, res
end

-- parses response to fetch() and store() commands
local function parse_fetch(res, what)
	local messages = {}
	for _, m in ipairs(res.FETCH) do
		local id, list = m:match("^(%d+) (.*)$")
		list = to_table(list)
		local msg = {id = id}
		for i = 1,#list,2 do
			msg[list[i]] = list[i+1]
			msg[math.ceil(i/2)] = list[i]
		end
		messages[#messages+1] = msg
	end
	return messages
end

function IMAP:fetch(what, sequence, uid)
	assert_arg(1, what).type('string', 'table', 'nil')
	assert_arg(2, sequence).type('string', 'nil')

	what = to_list(what or '(UID BODY[HEADER.FIELDS (DATE FROM SUBJECT)])')
	sequence = tostring(sequence) or '1:*'
	uid = uid and 'UID ' or ''

	local res = self:_do_cmd('%sFETCH %s %s', uid, sequence, what)
	return parse_fetch(res), res
end

function IMAP:store(mode, flags, sequence, silent, uid)
	assert_arg(1, mode).any('set', '+', '-')
	assert_arg(2, flags).type('string', 'table')
	assert_arg(3, sequence).type('string', 'number')

	mode = mode == 'set' and '' or mode
	flags = to_list(flags)
	sequence = tostring(sequence)
	silent = silent and '.SILENT' or ''
	uid = uid and 'UID ' or ''

	local res = self:_do_cmd('%sSTORE %s %sFLAGS%s %s', uid, sequence, mode, silent, flags)
	return parse_fetch(res), res
end

function IMAP:copy(sequence, mailbox)
	assert_arg(1, sequence).type('string', 'number')
	assert_arg(2, mailbox).type('string')

	sequence = tostring(sequence)
	return self:_do_cmd('COPY %s %s', sequence, mailbox)
end

return setmetatable(IMAP, {__call = function(_, ...) return IMAP.new(...) end})