# Flux website

This folder holds the Flux website at <https://bjarneo.github.io/flux/>.
It is static HTML, CSS, and JavaScript with no build step.
The [Pages workflow](../.github/workflows/pages.yml) publishes it when a push to `master` changes a file in `site/`.
It does not publish `tools/` and this README.

## Layout

| Path | Content |
| --- | --- |
| `index.html`, `style.css`, `main.js` | The page |
| `fonts/` | Mona Sans and JetBrains Mono as WebFonts, with their SIL Open Font License files |
| `img/phone/` | Captures of Flux for Android in demo mode, from `tools/capture-phone.sh` |
| `img/desk/` | Images of the Flux window, from `tools/capture-desk.sh` |
| `img/og.png` | The social preview, from `tools/render-og.sh` |
| `favicon.svg` | A copy of `dist/flux.svg` |

Each WebP image in `img/` has a `.json` file beside it that records the origin of the image.
The PNG preview keeps its origin in a text chunk.
The Pages workflow does not publish the `.json` files.

The page loads no file from another site.
`main.js` asks the GitHub API for the latest release, and then points the download links to its assets.
Without an answer, the links stay on the release in `index.html`.

## Preview

To preview the site, serve this folder:

```sh
python3 -m http.server 8765 --directory site
```

Then open <http://127.0.0.1:8765/>.

## Make the images again

1. To make the phone images, start an Android emulator with a 1080 x 2400 screen and night mode, and install a debug build of Flux for Android.
2. Run the phone capture with the serial of the emulator:

   ```sh
   ANDROID_SERIAL=emulator-5582 site/tools/capture-phone.sh
   ```

   The script sets the status bar clock to the time of each moment on the page.
   Use an emulator, not a personal phone. A capture shows the whole screen.
3. To make the images of the Flux window, build the window and run the desktop capture:

   ```sh
   make build-gui
   site/tools/capture-desk.sh
   ```

4. To make the social preview, run:

   ```sh
   site/tools/render-og.sh
   ```

When you add a release asset name or a new download, update the links in `index.html` and the asset patterns in `main.js`.
