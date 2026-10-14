#!/usr/bin/env python3
"""BEAM's colours as two Campfire themes, light and dark (owner, 2026-10-13).

    python3 -I scripts/beam/theme/beam_brand_theme.py

Reads Campfire's own theme, asset_sources/default_themes/campfire/light.zip, and writes
beam_light.zip and beam_dark.zip next to it: the same images (Campfire's logo, the Beam
girl, the coin icons), a theme.json with BEAM's colours, and the history's arrow icons in
BEAM's received / sent / swap colours. Deterministic: every entry keeps its order, bytes
and timestamp except the ones rewritten here, which get a fixed timestamp, so running it
twice gives the same files. lib/themes/beam/beam_themes.dart installs and offers them;
Campfire's light.zip stays the default and is not touched.

Where the colours come from: the web wallet's BEAM skin, pwa/docs/beam-brand-palette.json
(every value with its source in BEAM's own wallets: the desktop wallet's mainnet theme,
the browser extension, Android and iOS). Dark is BEAM's own wallet: navy #042548, cards
#103051, turquoise #00f6d2 with marine #032e49 on it, bluey-grey #8da1ad secondary text,
received #0bccf7, sent #da68f5, swaps #39fdf2, failed #ff746b, error #ff625c, warning
#f4ce4a. BEAM has no light theme; light is derived the same way as the web wallet's: the
navy becomes the ink, the backgrounds are its hue nearly white, the turquoise button keeps
its marine label, and every accent used as text keeps BEAM's hue, darkened to 4.5:1.
test/beam/theme/beam_theme_test.dart measures every text colour against what it sits on.
"""
import io
import json
import pathlib
import re
import zipfile

REPO = pathlib.Path(__file__).resolve().parents[3]
SRC = REPO / 'asset_sources/default_themes/campfire/light.zip'
OUT = REPO / 'asset_sources/default_themes/campfire'
FIXED_TIME = (2026, 10, 13, 0, 0, 0)
# lib/themes/beam/beam_themes.dart BeamThemes.version. theme.json's "version" is also Stack Wallet's
# image-format switch (StackTheme.fromJson: 1 -> ThemeAssets, 2 -> ThemeAssetsV2, 3 and up ->
# ThemeAssetsV3). Campfire's images are V3, so it must stay 3 or more: at 1 the app read them as V1, left
# its per-coin fields unset, and stopped at startup storing the theme (a black window on a new install and
# after updating; found in the 1.3.0 trial build, 2026-10-14). Bump it to make installed copies update.
VERSION = 17

# One palette per brightness, in the web wallet's token names (css/app.css, data-skin="beam").
DARK = dict(
    bg='042548', surface='103051', surface2='183657', text='FFFFFF', text2='D6D9E0',
    muted='8DA1AD', subtle='889DA9', primary='00F6D2', on_primary='032E49',
    primary_text='00F6D2', primary_disabled='2C5066', on_primary_disabled='889DA9',
    secondary='03445D', on_secondary='00F6D2', border='33566B', border_soft='1D3B5A',
    success_bg='03445D', success='00F6D2', error_bg='2A2E4B', error='FF746B',
    info_bg='053E62', info='0BCCF7', warn_bg='283E48', warn='F4CE4A',
    green='00F6D2', yellow='F4CE4A', red='FF625C', accent='00F6D2',
    incoming='0BCCF7', outgoing='DA68F5', swap='39FDF2', pending='F4CE4A', failed='FF625C',
    on_green='032E49', coin='00F6D2', on_coin='032E49', overlay='000000',
    shadow='4D000000', splash='35889DA9', highlight='44889DA9',
    eth_tag_bg='4D5798', eth_tag_text='FFFFFF', eth_wallet_tag_bg='2B3268', eth_wallet_tag_text='C7CCFF',
    sw_bottom='0B1624', nav_shadow='000000', inactive_icon='D6D9E0',
)
LIGHT = dict(
    bg='EEF4FA', surface='FFFFFF', surface2='E2EBF3', text='042548', text2='23405E',
    muted='566A76', subtle='8DA1AD', primary='00F6D2', on_primary='032E49',
    primary_text='007564', primary_disabled='D3E4E1', on_primary_disabled='7C918E',
    secondary='D9F7F2', on_secondary='00665A', border='D3E0EA', border_soft='F0F4F7',
    success_bg='D9F7F2', success='00665A', error_bg='FFE7E7', error='B80F0A',
    info_bg='DCF5FC', info='035E73', warn_bg='FDF3D6', warn='5C4700',
    green='007564', yellow='7D6407', red='D10700', accent='007564',
    incoming='04728B', outgoing='AB0DCE', swap='017972', pending='7D6407', failed='D10700',
    on_green='FFFFFF', coin='00F6D2', on_coin='032E49', overlay='111215',
    shadow='14042548', splash='358DA1AD', highlight='448DA1AD',
    eth_tag_bg='4D5798', eth_tag_text='FFFFFF', eth_wallet_tag_bg='F0F3FD', eth_wallet_tag_text='4D5798',
    sw_bottom='232323', nav_shadow='282E33', inactive_icon='FFFFFF',
)


def colors(p: dict, coin_colors: dict) -> dict:
    """Every colour of Stack Wallet's theme.json, from the palette."""
    c = lambda k: '0xFF' + p[k]  # noqa: E731
    raw = lambda v: '0x' + v  # noqa: E731
    coins = dict(coin_colors)
    coins['beam'] = c('coin')
    return {
        'coin': coins,
        'background': c('bg'),
        'background_app_bar': c('bg'),
        'overlay': c('overlay'),
        'accent_color_blue': c('primary_text'),
        'accent_color_green': c('green'),
        'accent_color_yellow': c('yellow'),
        'accent_color_red': c('error'),
        'accent_color_orange': c('yellow'),
        'accent_color_dark': c('text'),
        'shadow': raw(p['shadow']),
        'text_dark_one': c('text'),
        'text_dark_two': c('text2'),
        'text_dark_three': c('muted'),
        'text_white': '0xFFFFFFFF',
        'text_favorite': c('on_coin'),
        'text_error': c('error'),
        'text_restore': c('text'),
        'text_subtitle_one': c('muted'),
        'text_subtitle_two': c('muted'),
        'text_subtitle_three': c('muted'),
        'text_subtitle_four': c('border'),
        'text_subtitle_five': c('border_soft'),
        'text_subtitle_six': c('surface2'),
        'button_back_primary': c('primary'),
        'button_back_secondary': c('secondary'),
        'button_back_primary_disabled': c('primary_disabled'),
        'button_back_secondary_disabled': c('surface2'),
        'button_back_border': c('accent'),
        'button_back_border_disabled': c('border'),
        'button_back_border_secondary': c('border'),
        'button_back_border_secondary_disabled': c('border_soft'),
        'number_back_default': c('surface'),
        'numpad_back_default': c('primary'),
        'bottom_nav_back': c('surface'),
        'button_text_primary': c('on_primary'),
        'button_text_secondary': c('on_secondary'),
        # Stack's desktop text styles also draw ordinary text in this one: keep it readable.
        'button_text_primary_disabled': c('muted'),
        'button_text_secondary_disabled': c('subtle'),
        'button_text_border': c('text'),
        'button_text_disabled': c('subtle'),
        'button_text_borderless': c('primary_text'),
        'button_text_borderless_disabled': c('subtle'),
        'number_text_default': c('text'),
        'numpad_text_default': c('on_primary'),
        'bottom_nav_text': c('text'),
        'custom_text_button_enabled_text': c('primary_text'),
        'custom_text_button_disabled_text': c('subtle'),
        'switch_bg_on': c('accent'),
        'switch_bg_off': c('border'),
        'switch_bg_disabled': c('border_soft'),
        'switch_circle_on': c('on_green'),
        'switch_circle_off': '0xFFFFFFFF' if p is LIGHT else c('text2'),
        'switch_circle_disabled': c('surface2'),
        'step_indicator_bg_check': c('secondary'),
        'step_indicator_bg_number': c('secondary'),
        'step_indicator_bg_inactive': c('muted') if p is LIGHT else c('border'),
        'step_indicator_bg_lines': c('accent'),
        'step_indicator_bg_lines_inactive': c('border'),
        'step_indicator_icon_text': c('on_secondary'),
        'step_indicator_icon_number': c('on_secondary'),
        'step_indicator_icon_inactive': c('inactive_icon'),
        'checkbox_bg_checked': c('accent'),
        'checkbox_border_empty': c('muted'),
        'checkbox_bg_disabled': c('border'),
        'checkbox_icon_checked': c('on_green'),
        'checkbox_icon_disabled': c('surface'),
        'checkbox_text_label': c('text'),
        'snack_bar_back_success': c('success_bg'),
        'snack_bar_back_error': c('error_bg'),
        'snack_bar_back_info': c('info_bg'),
        'snack_bar_text_success': c('success'),
        'snack_bar_text_error': c('error'),
        'snack_bar_text_info': c('info'),
        'bottom_nav_icon_back': c('subtle'),
        'bottom_nav_icon_icon': c('text'),
        'bottom_nav_icon_icon_highlighted': c('primary_text'),
        'top_nav_icon_primary': c('text'),
        'top_nav_icon_green': c('green'),
        'top_nav_icon_yellow': c('yellow'),
        'top_nav_icon_red': c('red'),
        'settings_icon_back': c('secondary'),
        'settings_icon_icon': c('on_secondary'),
        'settings_icon_back_two': c('info_bg'),
        'settings_icon_element': c('incoming'),
        'text_field_active_bg': c('surface2'),
        'text_field_default_bg': c('surface2'),
        'text_field_error_bg': c('error_bg'),
        'text_field_success_bg': c('success_bg'),
        'text_field_error_border': c('error_bg'),
        'text_field_success_border': c('success_bg'),
        'text_field_active_search_icon_left': c('muted'),
        'text_field_default_search_icon_left': c('muted'),
        'text_field_error_search_icon_left': c('error'),
        'text_field_success_search_icon_left': c('success'),
        'text_field_active_text': c('text'),
        'text_field_default_text': c('muted'),
        'text_field_error_text': c('text'),
        'text_field_success_text': c('text'),
        'text_field_active_label': c('muted'),
        'text_field_error_label': c('error'),
        'text_field_success_label': c('success'),
        'text_field_active_search_icon_right': c('muted'),
        'text_field_default_search_icon_right': c('muted'),
        'text_field_error_search_icon_right': c('error'),
        'text_field_success_search_icon_right': c('success'),
        'settings_item_level_two_active_bg': c('surface'),
        'settings_item_level_two_active_text': c('text'),
        'settings_item_level_two_active_sub': c('muted'),
        'radio_button_icon_border': c('accent'),
        'radio_button_icon_border_disabled': c('subtle'),
        'radio_button_border_enabled': c('accent'),
        'radio_button_border_disabled': c('subtle'),
        'radio_button_icon_circle': c('accent'),
        'radio_button_icon_enabled': c('accent'),
        'radio_button_text_enabled': c('text2'),
        'radio_button_text_disabled': c('muted'),
        'radio_button_label_enabled': c('muted'),
        'radio_button_label_disabled': c('muted'),
        'info_item_bg': c('surface'),
        'info_item_label': c('muted'),
        'info_item_text': c('text'),
        'info_item_icons': c('primary_text'),
        'popup_bg': c('surface'),
        'currency_list_item_bg': c('surface2'),
        'sw_bg': c('bg') if p is DARK else c('surface'),
        'sw_mid': c('bg') if p is DARK else c('surface'),
        'sw_bottom': c('sw_bottom'),
        'bottom_nav_shadow': c('nav_shadow'),
        'favorite_star_active': c('primary_text'),
        'favorite_star_inactive': c('border'),
        'splash': raw(p['splash']),
        'highlight': raw(p['highlight']),
        'warning_foreground': c('warn'),
        'warning_background': c('warn_bg'),
        'loading_overlay_text_color': '0xFFF7F7F7',
        'my_stack_contact_icon_bg': c('surface2'),
        'text_confirm_total_amount': c('text'),
        'text_selected_word_table_iterm': c('text'),
        'rate_type_toggle_color_on': c('surface2'),
        'rate_type_toggle_color_off': c('surface'),
        'rate_type_toggle_desktop_color_on': c('surface2'),
        'rate_type_toggle_desktop_color_off': c('border'),
        'eth_tag_text': c('eth_tag_text'),
        'eth_tag_bg': c('eth_tag_bg'),
        'eth_wallet_tag_text': c('eth_wallet_tag_text'),
        'eth_wallet_tag_bg': c('eth_wallet_tag_bg'),
        'token_summary_text_primary': c('text'),
        'token_summary_text_secondary': c('muted'),
        'token_summary_bg': c('surface2'),
        'token_summary_button_bg': c('surface'),
        'token_summary_icon': c('primary_text'),
        'box_shadows': {
            'standard': {'color': raw(p['shadow']), 'spread_radius': 3.0, 'blur_radius': 4.0},
            'home_view_button_bar': {'color': raw(p['shadow']), 'spread_radius': 3.0, 'blur_radius': 4.0},
        },
    }


# The history's icons (theme assets receive / send / tx_exchange and their pending and failed
# forms): Campfire's arrows, in BEAM's colours. The disc behind each arrow is the colour at 15%
# instead of 40%, so the arrow reads at 3:1 or more on it in both themes; the pending and failed
# badges take BEAM's warning and error colours.
ICONS = {
    'tx-icon-receive': 'incoming', 'tx-icon-receive-pending': 'incoming', 'tx-icon-receive-failed': 'incoming',
    'tx-icon-send': 'outgoing', 'tx-icon-send-pending': 'outgoing', 'tx-icon-send-failed': 'outgoing',
    'tx-exchange-icon': 'swap', 'tx-exchange-icon-pending': 'swap', 'tx-exchange-icon-failed': 'swap',
}
CAMPFIRE_ARROW = {'incoming': '#00A578', 'outgoing': '#FE805C', 'swap': '#0056D2'}


def recolour(svg: str, kind: str, p: dict) -> str:
    out = svg.replace(CAMPFIRE_ARROW[kind], '#' + p[kind])
    out = out.replace('opacity="0.4"', 'opacity="0.15"')
    out = out.replace('#F4C517', '#' + p['pending']).replace('#C00205', '#' + p['failed'])
    # A badge's mark sits on the badge colour: marine on BEAM's bright dark-theme colours.
    if p is DARK:
        out = re.sub(r'stroke="white"', 'stroke="#032E49"', out)
    return out


def build(name: str, title: str, brightness: str, p: dict) -> bytes:
    src = zipfile.ZipFile(SRC)
    base = json.loads(src.read('theme.json'))
    assert base['version'] >= 3 and VERSION >= 3, 'the V3 image format (see VERSION)'
    theme = {
        'version': VERSION,
        'name': title,
        'id': name,
        'brightness': brightness,
        'colors': colors(p, base['colors']['coin']),
        'assets': base['assets'],
    }
    assert set(theme['colors']) == set(base['colors']), set(theme['colors']) ^ set(base['colors'])
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w') as dst:
        for info in src.infolist():
            stem = pathlib.PurePosixPath(info.filename).stem
            if info.filename == 'theme.json':
                data = (json.dumps(theme, indent=2, ensure_ascii=False) + '\n').encode()
            elif info.filename.startswith('assets/svg/') and stem in ICONS and info.filename.endswith('.svg'):
                data = recolour(src.read(info).decode(), ICONS[stem], p).encode()
            else:
                dst.writestr(info, src.read(info), compress_type=info.compress_type)
                continue
            zi = zipfile.ZipInfo(info.filename, FIXED_TIME)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o644 << 16
            dst.writestr(zi, data)
    src.close()
    return out.getvalue()


def main() -> None:
    for name, title, brightness, p in (
        ('beam_light', 'BEAM light', 'light', LIGHT),
        ('beam_dark', 'BEAM dark', 'dark', DARK),
    ):
        data = build(name, title, brightness, p)
        (OUT / f'{name}.zip').write_bytes(data)
        print(f'{(OUT / name).relative_to(REPO)}.zip: {len(data) // 1024} KB')


if __name__ == '__main__':
    main()
