// Options the stack itself sets in the web client's config.js. init copies
// this file into data/web/custom-config.js on every start, followed by
// conf/branding/custom-config.js if the operator supplies one.

// Without this the client relays its connection to the bridge over TURN on TCP
// only -- TLS through TURNS_HOST. Networks that block UDP 10000 but let UDP 443
// out can then relay over UDP, which is lighter.
config.useTurnUdp = true;
