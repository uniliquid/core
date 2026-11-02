<?php

// Test only: a minimal HTTPS server for tests/member-sync-test.php (as the
// one of PPOE/admidio-addons).
// php https-server.php <port> <certificate and key PEM> <token> <document file>
//   /liquid-members.php  200 and the document file, or 403 without "Bearer <token>"
//   /error      500 (with a valid body)
//   /redirect   302 to /liquid-members.php
//   /slow       as /liquid-members.php, after 3 seconds
//   /noreason   as /liquid-members.php, with the status line "HTTP/1.0 200" (no reason)
//   /status2000 status line "HTTP/1.0 2000 OK" (with a valid body)
//   /big        200 and a valid document of 1 MiB + 1 byte
//   /trickle    200 at once, then a valid body of 8 bytes, one per second
//   /tricklehead the status line at once, then 8 header lines, one per second
//   /short      200 and the document file, Content-Length one byte more (the
//               connection closes early, the body is cut short)
//   /long       200 and the document file, Content-Length one byte less
//   /badlength  200 and the document file, Content-Length "<length>x"
// One request at a time; HTTP/1.0, the connection is closed after each.

[, $port, $pem, $token, $document] = $argv;
$server = stream_socket_server(
    "ssl://127.0.0.1:$port",
    $errno,
    $error,
    STREAM_SERVER_BIND | STREAM_SERVER_LISTEN,
    stream_context_create(['ssl' => ['local_cert' => $pem]]),
);
if ($server === false) {
    fwrite(STDERR, "https-server: $error\n");
    exit(1);
}
while (true) {
    // False when the client rejects the certificate during the handshake.
    $connection = @stream_socket_accept($server, 3600);
    if ($connection === false) {
        continue;
    }
    $head = [];
    while (($line = fgets($connection)) !== false && rtrim($line) !== '') {
        $head[] = rtrim($line);
    }
    $path = explode(' ', $head[0] ?? '')[1] ?? '';
    $headers = '';
    $body = '[]';
    $length = null;
    if ($path === '/liquid-members.php' || $path === '/noreason') {
        if (in_array("Authorization: Bearer $token", $head, true)) {
            $status = $path === '/noreason' ? '200' : '200 OK';
            $body = file_get_contents($document);
        } else {
            $status = '403 Forbidden';
            $body = '';
        }
    } elseif ($path === '/short' || $path === '/long' || $path === '/badlength') {
        $status = '200 OK';
        $body = file_get_contents($document);
        $length = ['/short' => strlen($body) + 1, '/long' => strlen($body) - 1, '/badlength' => strlen($body) . 'x'][$path];
    } elseif ($path === '/error') {
        $status = '500 Internal Server Error';
    } elseif ($path === '/redirect') {
        $status = '302 Found';
        $headers = "Location: https://127.0.0.1:$port/liquid-members.php\r\n";
    } elseif ($path === '/status2000') {
        $status = '2000 OK';
    } elseif ($path === '/big') {
        $status = '200 OK';
        $body = '[' . str_repeat(' ', 1048576 - 1) . ']';
    } elseif ($path === '/trickle' || $path === '/tricklehead') {
        $parts = $path === '/trickle'
            ? array_merge(["HTTP/1.0 200 OK\r\nConnection: close\r\n\r\n"], str_split('[      ]'))
            : array_merge(["HTTP/1.0 200 OK\r\n"], array_fill(0, 8, "X-Pad: a\r\n"), ["\r\n[]"]);
        foreach ($parts as $i => $part) {
            if ($i > 0) {
                sleep(1);
            }
            if (@fwrite($connection, $part) === false) {
                break;
            }
        }
        fclose($connection);
        continue;
    } elseif ($path === '/slow') {
        sleep(3);
        $status = '200 OK';
        $body = file_get_contents($document);
    } else {
        $status = '404 Not Found';
    }
    @fwrite($connection, "HTTP/1.0 $status\r\nContent-Type: application/json\r\nContent-Length: " . ($length ?? strlen($body))
        . "\r\n{$headers}Connection: close\r\n\r\n$body");
    fclose($connection);
}
