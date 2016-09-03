## Erlbeat

### Pre req
You need to start both `inets` and `erlbeat` before continuing

### Usage
```
1> application:start(inets).
ok
2> application:start(erlbeat).
ok
3> erlbeat:register_service(Arguments)
```
Eg:
`erlbeat:register_service([{protocol, http}, {uri, "http://www.google.com"}, {user_email, undefined}, {user_mobile, undefined}]).`
