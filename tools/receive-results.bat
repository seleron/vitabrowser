@echo off
rem VitaBrowser: receive the Vita's log and plot dumps over Wi-Fi.
rem Start this BEFORE launching VitaBrowser on the Vita; leave it open.
rem Each launch lands in results\net-<date>-<time>-<boot>\ (never an old copy).
rem Windows may ask whether Python can use the network: allow Private networks.
rem See docs/phase-0/10-hardware-test-plan.md, Run 6.
cd /d "%~dp0"
if exist reference-dumps (
  py -3 vita-netlog.py --out results --reference reference-dumps
) else (
  py -3 vita-netlog.py --out results
)
pause
