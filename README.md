# O3-Shop

![O3-Shop logo](https://www.o3-shop.com/wp-content/uploads/elementor/thumbs/o3-shop-logo-1-pw26sv9s5904cmoq6lyf07h4lpklvc6insy20a756o.png "O3-Shop")

## Project package

This package ist part of the O3-Shop. For more informations, consult the [documentation](https://docs.o3-shop.com) and join the community on [https://community.o3-shop.com](https://community.o3-shop-com).

- License: GNU General Public License 3 [https://www.gnu.org/licenses/gpl-3.0.de.html](https://www.gnu.org/licenses/gpl-3.0.de.html)
- Website: [https://www.O3-Shop.com](https://www.O3-Shop.com)

## Demo Docker image

Every published release (release candidates included) gets a ready-to-run demo image: the shop, installed with demo data, plus its database in one container. Images exist from the first release that contains `docker/demo/`.

> **For demos only, not for production.** The database runs inside the container and starts from the original demo state every time a new container is created.

```bash
docker run -p 8080:80 ghcr.io/o3-shop/o3-shop-demo:<release-tag>
```

- Shop: http://localhost:8080
- Admin: http://localhost:8080/admin/ (`admin@example.com` / `admin123`)

`<release-tag>` is a release such as `v1.7.2`; release candidates have their own tags (`v1.7.3-RC1`). `latest` follows the newest final release.

| Variable | Default | Purpose |
|---|---|---|
| `O3_SHOP_URL` | `http://localhost:8080` | URL the shop is reached under. Set it when you use another port or host, e.g. `docker run -p 9000:80 -e O3_SHOP_URL=http://localhost:9000 …` |
| `O3_ADMIN_EMAIL` | `admin@example.com` | Admin login |
| `O3_ADMIN_PASSWORD` | `admin123` | Admin password |

Changes stay as long as you keep the container (`docker stop` / `docker start`). To keep them across new containers, use named volumes for the database and the uploaded pictures:

```bash
docker run -p 8080:80 \
  -v o3-demo-db:/var/lib/mysql \
  -v o3-demo-pictures:/var/www/html/source/out/pictures \
  ghcr.io/o3-shop/o3-shop-demo:<release-tag>
```

On first use Docker fills empty named volumes with the image's demo data. Don't use empty bind mounts (host directories) for these paths: they hide the installed data and the shop won't start. A volume created with an older image keeps that version's database, so start with fresh volumes when you switch to a newer release.

**The demo sends no e-mail.** Registration, order and newsletter mails are accepted and then discarded; `docker logs` shows one line per discarded mail with its recipient. The shop's SMTP settings stay empty even if you set them in the admin.

Build it locally from this repository: `docker build -f docker/demo/Dockerfile -t o3-shop-demo .`

## Bugs and issues

If you experience any bugs or issues, please report them in the section **O3-Shop (all versions)** of [https://github.com/o3-shop/o3-shop/issues](https://github.com/o3-shop/o3-shop/issues).
