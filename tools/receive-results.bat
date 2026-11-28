@echo off
rem VitaBrowser: receive the Vita's log and plot dumps over Wi-Fi.
rem Start this BEFORE launching VitaBrowser on the Vita; leave it open.
rem Each launch lands in results\net-<date>-<time>-<boot>\ (never an old copy).
rem Windows may ask whether Python can use the network: allow Private networks.
rem See docs/phase-0/10-hardware-test-plan.md, Run 6.
rem Run 44: a crash BEFORE the app starts its netlog sends nothing. The
rem receiver now prints "receiver alive" every 30 s of quiet and warns
rem "no VitaBrowser launch seen in 60 s" -- if you launched it, it died early.
cd /d "%~dp0"
echo VitaBrowser receiver. Start it BEFORE launching the app; leave it open.
echo  - "-- [time] receiver alive" every 30 s of quiet: if that clock stops,
echo    this window is frozen (a click starts a selection): press Esc.
echo  - "!! no VitaBrowser launch seen": if you launched it, it crashed before
echo    its netlog started. Relaunch; if still nothing, try the default VPK.
echo.
if exist reference-dumps (
  py -3 vita-netlog.py --out results --reference reference-dumps
) else (
  py -3 vita-netlog.py --out results
)
pause
