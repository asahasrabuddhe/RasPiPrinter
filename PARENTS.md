# Printing from the laptop

The small Raspberry Pi box connects the HP printer to the home network. Once it is set up, any laptop or phone at home can print.

## Connect the box (once)

1. Plug the network cable from the box into the Wi-Fi router.
2. Plug the printer's USB cable into the box.
3. Plug in the box's power. Switch on the printer.

The first time, wait 30 minutes before the next step. After that the box is ready about two minutes after power on. Leave it on all the time.

## Add the printer in Windows (once)

1. Open **Start**, then **Settings**.
2. Go to **Bluetooth & devices**, then **Printers & scanners**.
3. Click **Add device**.
4. Wait for **HP LaserJet P1008 @ ajitem-pi-printer** to appear, then click **Add device** next to it.

That is it. Choose this printer when you print.

### If the printer does not appear

1. After about a minute, click **Add manually**.
2. Choose **Select a shared printer by name**.
3. Type `http://ajitem-pi-printer.local:631/printers/HP_LaserJet_P1008`
4. Click **Next**. If Windows asks for a driver, pick **Microsoft IPP Class Driver**.
5. Finish.

## Printing from a phone

The phone must be on the home Wi-Fi.

**iPhone or iPad:** open what you want to print, tap **Share**, then **Print**, and choose **HP LaserJet P1008 @ ajitem-pi-printer**.

**Android:** the first time, go to **Settings**, **Connected devices**, **Connection preferences**, **Printing**, and switch on **Default Print Service**. After that, in any app tap the menu, then **Print**, then **Select printer**, and choose the HP LaserJet P1008.

## If printing stops working

1. Switch the printer off and on again, then wait one minute.
2. If that does not help, unplug the box's power, plug it back in and wait two minutes.
3. Still stuck? Call Ajitem.
