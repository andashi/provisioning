# Apply the shared appearance document to a zone that already uses Andashi Keyboard.
# Uses the caller's package query, ingest transport, and state-provider reader.

keyboard_look_matches() {   # $1=effective JSON $2=generated launcher JSON file
  jq -e --slurpfile wanted "$2" '
    def select_keys($keys):
      with_entries(select(.key as $key | $keys | index($key) != null));
    def keyboard_palette:
      select_keys(["light", "dark"])
      | with_entries(.value |= select_keys(["surface", "onSurface", "onSurfaceVariant", "primary"]))
      | with_entries(select(.value != {}));

    . as $effective
    | $wanted[0] as $config
    | ($config.appearance.glass // {} | select_keys(["blur", "tint", "floor", "scheme"])) as $glass
    | ($config.appearance.theme.palette // null) as $palette
    | $effective.schemaVersion == 2
      and ($effective.appearance.glass | type) == "object"
      and all($glass | to_entries[]; $effective.appearance.glass[.key] == .value)
      and ($palette == null or
        (($effective.appearance.theme.palette // {}) | keyboard_palette) == ($palette | keyboard_palette))
  ' <<<"$1" >/dev/null
}

sync_keyboard_look() {   # $1=uid $2=launcher file $3=file sha256 $4=profile label
  local uid="$1" cfg="$2" hash="$3" label="$4" PKG=org.andashi.keyboard
  local packages report effective attempt
  packages="$(ash_ro pm list packages --user "$uid" "$PKG" | tr -d '\r')" \
    || { warn "$label: could not check whether Andashi Keyboard is installed"; return 1; }
  case $'\n'"$packages"$'\n' in
    *$'\n'"package:$PKG"$'\n'*) ;;
    *) return 0 ;;
  esac

  if report="$(query_state diagnostics "$uid")" \
     && jq -e --arg hash "$hash" '.success == true and .configSha256 == $hash' <<<"$report" >/dev/null \
     && effective="$(query_state config "$uid")" \
     && keyboard_look_matches "$effective" "$cfg"; then
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    log "$label: would update Andashi Keyboard from the shared launcher file"
    return 0
  fi
  if ! ingest_write "content://$PKG.config-ingest/launcher.json" "$cfg" "$uid"; then
    warn "$label: could not upload the shared look to Andashi Keyboard"
    return 1
  fi

  for ((attempt=0; attempt<15; attempt++)); do
    if report="$(query_state diagnostics "$uid")" \
       && jq -e --arg hash "$hash" '.configSha256 == $hash' <<<"$report" >/dev/null; then
      if jq -e '.success == true' <<<"$report" >/dev/null \
         && effective="$(query_state config "$uid")" \
         && keyboard_look_matches "$effective" "$cfg"; then
        ok "$label: Andashi Keyboard look verified"
        return 0
      fi
      if jq -e '.success == false' <<<"$report" >/dev/null; then
        warn "$label: Andashi Keyboard rejected the uploaded look"
        return 1
      fi
    fi
    sleep 1
  done
  warn "$label: Andashi Keyboard did not confirm the uploaded look"
  return 1
}
