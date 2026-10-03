# Writes looks.json: one LPC generator selection (its URL-hash string) per look. See README.md.
import json
def M(skin): return f"sex=male&body=Body_Color_{skin}&head=Human_Male_{skin}&expression=Neutral_{skin}"
def F(skin): return f"sex=female&body=Body_Color_{skin}&head=Human_Female_{skin}&expression=Neutral_{skin}"
STAFF = "clothes=Shortsleeve_Polo_green&legs=Pants_charcoal&shoes=Basic_Shoes_black"
# Week 26 warehouse crew (forklift drivers): yellow hard hat (the kettle helm in
# gold with a yellow crown), safety-yellow overalls, charcoal long sleeves, boots.
WAREHOUSE = "clothes=Longsleeve_2_charcoal&overalls=Overalls_yellow&legs=Pants_charcoal&shoes=Basic_Boots_brown&hat=Kettle_helm_gold&hat_secondary=Kettle_Inner_yellow"
looks = {
 # customers: everyday clothes, no green tops (green = staff)
 "customer_1": M("light") + "&hair=Messy1_chestnut&clothes=TShirt_sky&legs=Pants_navy&shoes=Basic_Shoes_brown",
 "customer_2": F("brown") + "&hair=Ponytail_black&clothes=Longsleeve_2_VNeck_rose&legs=Long_Pants_charcoal&shoes=Basic_Shoes_black",
 "customer_3": M("bronze") + "&hair=Afro_black&beard=Trimmed_Beard_black&clothes=TShirt_yellow&legs=Shorts_tan&shoes=Sandals_brown",
 "customer_4": F("olive") + "&hair=Bob_blonde&clothes=Cardigan_lavender&legs=Leggings_gray&shoes=Basic_Shoes_walnut",
 "customer_5": M("amber") + "&hair=Balding_gray&mustache=Mustache_gray&clothes=Longsleeve_2_Buttoned_orange&legs=Cuffed_Pants_tan&shoes=Basic_Shoes_brown",
 "customer_6": F("taupe") + "&hair=Long_straight_redhead&clothes=TShirt_Scoop_purple&legs=Pants_blue&shoes=Basic_Boots_brown",
 # staff (cashiers, one fixed identity per register slot)
 "cashier_1": F("light") + "&hair=High_ponytail_dark_brown&" + STAFF,
 "cashier_2": M("brown") + "&hair=Buzzcut_black&" + STAFF,
 "cashier_3": F("amber") + "&hair=Pixie_black&" + STAFF,
 "cashier_4": M("olive") + "&hair=Curly_short_dark_brown&beard=5_O'clock_Shadow_dark_brown&" + STAFF,
 "cashier_5": F("bronze") + "&hair=Bangs_bun_black&" + STAFF,
 # players: same uniform, a different face per player slot
 "player_1": M("light") + "&hair=Parted_chestnut&" + STAFF,
 "player_2": F("taupe") + "&hair=Shoulderl_blonde&" + STAFF,
 "player_3": M("bronze") + "&hair=Flat_top_fade_black&" + STAFF,
 "player_4": F("olive") + "&hair=Curly_long_ginger&" + STAFF,
 # the manager: suit
 "manager": M("light") + "&hair=Parted_gray&clothes=Collared/Formal_Longsleeve_white&legs=Formal_Pants_black&shoes=Basic_Shoes_black&jacket=Collared_coat_charcoal&neck=Necktie_red",
 # Week 26 forklift drivers: one fixed identity per forklift, same crew
 # uniform, own face. Expressions do the comedy: the Produce (hazard) driver
 # is permanently alarmed at what he keeps hitting; the delivery driver has
 # unloaded this truck one time too many.
 "driver_produce": M("amber").replace("Neutral_amber", "Shock_amber") + "&hair=Messy1_black&" + WAREHOUSE,
 "driver_delivery": F("light").replace("Neutral_light", "Rolling_Eyes_light") + "&hair=Ponytail_red&" + WAREHOUSE,
}
json.dump(looks, open('looks.json','w'), indent=1)
