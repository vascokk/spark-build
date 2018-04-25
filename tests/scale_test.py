import sys
import time
from threading import Thread

import utils


MONTE_CARLO_APP_URL = "http://xhuynh-dev.s3.amazonaws.com/monte-carlo-portfolio.py"


def submit_job(dispatcher_service_name):
    args = ["--conf", "spark.cores.max=1",
            "--conf", "spark.mesos.containerizer=mesos",
            #"--conf", "spark.mesos.driverEnv.SPARK_USER=root", # Run as root on centos
            ]

    app_args = "100000 50"

    utils.submit_job(
        app_name="/{}".format(dispatcher_service_name),
        app_url=MONTE_CARLO_APP_URL,
        app_args=app_args,
        verbose=False,
        args=args)


def submit_loop(launch_rate_per_min, dispatchers):
    sec_between_submits = 60 / launch_rate_per_min
    print("sec_between_submits: {}".format(sec_between_submits))
    num_dispatchers = len(dispatchers)
    print("num_dispatchers: {}".format(num_dispatchers))

    dispatcher_index = 0
    while(True):
        t = Thread(target=submit_job, args=(dispatchers[dispatcher_index],))
        t.start()
        dispatcher_index = (dispatcher_index + 1) % num_dispatchers
        print("sleeping {} sec.".format(sec_between_submits))
        time.sleep(sec_between_submits)


if __name__ == "__main__":
    """
        Usage: python scale_test.py [dispatchers_file] [launch_rate_per_min]
    """

    if len(sys.argv) < 3:
        print("Usage: scale_test.py [dispatchers_file] [launch_rate_per_min]")
        sys.exit(2)

    dispatchers_file = sys.argv[1]
    print("dispatchers_file: {}".format(dispatchers_file))
    with open(dispatchers_file) as f:
        dispatchers = f.read().splitlines()
    print("dispatchers: {}".format(dispatchers))

    launch_rate_per_min = int(sys.argv[2])
    print("launch_rate_per_min: {}".format(launch_rate_per_min))

    submit_loop(launch_rate_per_min, dispatchers)