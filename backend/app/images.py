import io
import warnings

from PIL import Image, ImageOps, UnidentifiedImageError


def prepare_image(content: bytes) -> bytes:
    if not content or len(content) >= 10_000_000:
        raise ValueError("Choose a JPEG or PNG under 10 MB.")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(content)) as image:
                if image.format not in {"JPEG", "PNG"}:
                    raise ValueError("Only JPEG and PNG images are supported.")
                if image.width * image.height > 25_000_000:
                    raise ValueError("Choose an image under 25 megapixels.")
                image = ImageOps.exif_transpose(image)
                image.thumbnail((2560, 2560))
                if min(image.size) < 1080:
                    raise ValueError("HD analysis needs at least 1080 pixels on the short side.")
                result = io.BytesIO()
                # Re-encoding strips EXIF/GPS and other unnecessary metadata.
                image.convert("RGB").save(result, format="JPEG", quality=92)
                return result.getvalue()
    except (
        UnidentifiedImageError,
        OSError,
        Image.DecompressionBombWarning,
        Image.DecompressionBombError,
    ) as exc:
        raise ValueError("The image could not be decoded safely.") from exc
