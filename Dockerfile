FROM python AS base
ENV DEBIAN_FRONTEND noninteractive

RUN apt update                   \
&&  apt full-upgrade -y          \
&&  rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip
RUN pip install --no-cache-dir --upgrade -r requirements.txt
RUN pip install --no-cache-dir --upgrade ia_l0st
ENTRYPOINT ["python", "-m", "ia_l0st"]
