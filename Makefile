build: Dockerfile *.yml *.sh
	docker build . -t hellomd/kube-ci

run:
	docker run -it --name kube-ci hellomd/kube-ci /bin/bash 
