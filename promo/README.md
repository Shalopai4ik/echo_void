# Промо-материалы «Эхо Пустоты»

| Файл | Что это |
| --- | --- |
| `echo_of_void_trailer.mp4` | Кинематографический трейлер, 62 с, 1920×1080, H.264 + AAC. Снят в движке на реальных системах игры (Movie Maker Godot). |
| `presentation/echo_of_void_presentation.html` | Презентация, 13 слайдов. Открыть в браузере: ← → / пробел — листать, F — полный экран. Шрифты подгружаются из Google Fonts (нужен интернет). |
| `presentation/echo_of_void_presentation.pdf` | Та же презентация в PDF, 1920×1080 на страницу. |
| `presentation/images/` | Кадры трейлера и скриншоты интерфейса, использованные в презентации. |

Пересобрать трейлер: `tools\trailer\make_trailer.ps1 -Godot <godot.exe> -Ffmpeg <ffmpeg.exe>`,
затем скопировать `build/trailer/echo_of_void_trailer.mp4` сюда.
Сценарий трейлера — `tools/trailer/trailer.gd`.

Папка помечена `.gdignore` (Godot её не импортирует) и исключена из экспорта игры.
