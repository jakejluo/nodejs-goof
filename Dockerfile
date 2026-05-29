# FROM node:6-stretch
FROM node:18-bullseye

RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
RUN mkdir /usr/src/goof
RUN mkdir /tmp/extracted_files
COPY . /usr/src/goof
WORKDIR /usr/src/goof

RUN npm update
RUN npm install
EXPOSE 3001
EXPOSE 9229
ENTRYPOINT ["npm", "start"]
