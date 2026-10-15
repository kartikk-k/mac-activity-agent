#!/usr/bin/env python3
"""Measure a running process's actual cumulative CPU time, as percent of one core."""
import argparse, subprocess, time, json
p=argparse.ArgumentParser();p.add_argument('pid',type=int);p.add_argument('--seconds',type=float,default=45);p.add_argument('--label',default='sample');a=p.parse_args()
def sample():
    value=subprocess.check_output(['/bin/ps','-p',str(a.pid),'-o','time=']).decode().strip()
    parts=value.replace('-',':').split(':')
    return sum(float(v)*m for v,m in zip(reversed(parts),[1,60,3600,86400]))
start=sample();clock=time.monotonic();time.sleep(a.seconds);end=sample();elapsed=time.monotonic()-clock
print(json.dumps({'label':a.label,'pid':a.pid,'wall_seconds':round(elapsed,3),'cpu_seconds':round(end-start,3),'cpu_percent_one_core':round((end-start)/elapsed*100,3)},indent=2))
