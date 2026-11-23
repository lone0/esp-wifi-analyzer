unit mosaicobmgrdeps;

{$mode objfpc}{$H+}

{ gen_bmgr_codes contains this Mosaico board's monolithic descriptor table.
  Its strong board runtime references optional audio/camera/battery/button
  code even though wifi-analyzer initializes only display + touch. Keep
  that app-specific closure here instead of burdening c_bmgr's API binding. }
{$linklib espressif__bq27220}
{$linklib espressif__button}
{$linklib espressif__esp_video}
{$linklib espressif__esp_cam_sensor}
{$linklib espressif__esp_codec_dev}
{$linklib esp_driver_i2s}
{$linklib esp_driver_cam}
{$linklib esp_hal_i2s}
{$linklib esp_hal_cam}
{$linklib espressif__esp_sccb_intf}
{$linklib espressif__esp_lcd_touch_cst9220}

interface

implementation

end.
