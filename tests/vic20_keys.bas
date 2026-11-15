10 n=0
20 get a$:if a$="" then 20
30 poke 4096+512+256+n,asc(a$):n=n+1:goto 20
