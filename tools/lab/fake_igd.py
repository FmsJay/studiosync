#!/usr/bin/env python3
"""StudioSync lab: a stand-in home router's UPnP (an Internet Gateway Device: the SSDP search answer, its description, GetExternalIPAddress)
naming --wan as its own internet address. Runs in the router VM's "home" namespace in double-NAT mode (routerlab.sh double on), so the relay
hub behind it reads a WAN address in 100.64.0.0/10 and Health says it's behind CGNAT (docs/rt/rt-nat3.md round 2). Answers those three
requests only; no port mappings. Standard library only.

  python3 fake_igd.py --wan 100.64.77.2 --lan 10.77.0.1 [--http 5000]
"""
import argparse, socket, struct, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ST = "urn:schemas-upnp-org:service:WANIPConnection:1"
DESC = ('<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1'
        '</deviceType><friendlyName>StudioSync lab router</friendlyName><serviceList><service><serviceType>' + ST + '</serviceType>'
        '<serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId><controlURL>/ctl/IPConn</controlURL><SCPDURL>/WANIPCn.xml</SCPDURL></service>'
        '</serviceList></device></root>')


def soap(wan):
    return ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
            '<s:Body><u:GetExternalIPAddressResponse xmlns:u="' + ST + '"><NewExternalIPAddress>' + wan +
            '</NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body></s:Envelope>')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wan", required=True)
    ap.add_argument("--lan", required=True, help="this router's own address on the clients' side")
    ap.add_argument("--http", type=int, default=5000)
    a = ap.parse_args()
    socket.inet_aton(a.wan), socket.inet_aton(a.lan)

    class H(BaseHTTPRequestHandler):
        def reply(self, body):
            b = body.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/xml")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            if self.path == "/rootDesc.xml":
                self.reply(DESC)
            else:
                self.send_error(404)

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if self.path == "/ctl/IPConn" and "GetExternalIPAddress" in (self.headers.get("SOAPAction") or ""):
                self.reply(soap(a.wan))
            else:
                self.send_error(500)

    threading.Thread(target=HTTPServer((a.lan, a.http), H).serve_forever, daemon=True).start()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", 1900))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, struct.pack("4s4s", socket.inet_aton("239.255.255.250"), socket.inet_aton(a.lan)))
    loc = "http://%s:%d/rootDesc.xml" % (a.lan, a.http)
    print("UPnP stand-in: WAN %s, description %s" % (a.wan, loc), flush=True)
    while True:
        data, addr = s.recvfrom(1500)
        if data.startswith(b"M-SEARCH") and b"ssdp:discover" in data:
            s.sendto(("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n"
                      "USN: uuid:studiosync-lab::urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\nLOCATION: " + loc + "\r\n\r\n").encode(), addr)


if __name__ == "__main__":
    sys.exit(main())
