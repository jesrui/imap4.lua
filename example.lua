require 'luarocks.require'

local imap4 = require 'imap4'

-- if in doubt, see RFC 3501:
-- https://tools.ietf.org/html/rfc3501#section-6

-- create new imap4 connection
-- port is optional and defaults to 143
local imap = imap4('localhost', 143)

-- print the servers capabilities
print(table.concat(imap:capability(), ', '))

-- make sure we can do what we want to
assert(imap:isCapable('IMAP4rev1'))

-- login. warning: this is sent in plaintext!
-- either tunnel this over ssh, or use tls: imap:starttls(params)
imap:login(user, pass)

-- imap:lsub() lists all subscribed mailboxes.
for mb, info in pairs(imap:lsub()) do
	-- imap:status(mailbox, items) queries status of a mailbox
	local stat = imap:status(mb, {'MESSAGES', 'RECENT', 'UNSEEN'})
	print(mb, stat.MESSAGES, stat.RECENT, stat.UNSEEN)
end

-- select INBOX with read only permissions
local info = imap:examine('INBOX')
print(info.exist, info.recent)

-- list info on the 4 most recent mails
-- see https://tools.ietf.org/html/rfc3501#section-6.4.5
for _,v in pairs(imap:fetch('BODY.PEEK[HEADER.FIELDS (From Date Subject)]', (info.exist-4)..':*')) do
	-- v contains the response as mixed, nested table.
	-- keys are stored in the list part.
	-- in this example, v[1] = BODY[HEADER.FIELDS ("From" "To" "Date" "Subject")]
	print(v.id, v[v[1]])
end

-- close connection
imap:logout()