/* Network probe for the phase 0 check: resolve a host and open one TCP connection to port 443.
   phase0-test.sh signs it with the Developer ID as com.valentorassa.netshield.probe, so the
   filter sees code with our Team ID and no [[allow]] rule. Exit 0: connected; 1: the connection
   failed; 2: the name did not resolve. From the phase 0 draft ~/netshield-fase0/probe.c. */
#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *host = argc > 1 ? argv[1] : "pypi.org";
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_socktype = SOCK_STREAM;
    int rc = getaddrinfo(host, "443", &hints, &res);
    if (rc != 0) {
        printf("dns %s: %s\n", host, gai_strerror(rc));
        return 2;
    }
    int s = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (s >= 0 && connect(s, res->ai_addr, res->ai_addrlen) == 0) {
        printf("connect %s:443 OK\n", host);
        close(s);
        freeaddrinfo(res);
        return 0;
    }
    printf("connect %s:443 failed: %s\n", host, strerror(errno));
    freeaddrinfo(res);
    return 1;
}
