⚠️ One thing to note

After install, Docker runs as root.
If you want smoother usage later:

sudo usermod -aG docker varsix
Then relogin.
You're now good to run
sudo ./actools.sh fresh
