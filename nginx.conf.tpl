worker_processes WORKERS;
error_log /dev/null crit;
pid /tmp/nginx.pid;
events {
    worker_connections 10240;
}
http {
    access_log off;
    keepalive_timeout 300s;
    keepalive_requests 10000000;
    server {
        listen 80;
        location = / {
            default_type text/plain;
            return 200 "Hello, World!";
        }
    }
}
