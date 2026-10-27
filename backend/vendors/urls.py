from django.urls import path

from vendors.views import (
    BillDetailView,
    BillListView,
    VendorDetailView,
    VendorListView,
)

app_name = "api_vendors"
urlpatterns = [
    path("", VendorListView.as_view()),
    path("bills/", BillListView.as_view()),
    path("bills/<uid:pk>/", BillDetailView.as_view()),
    path("<uid:pk>/", VendorDetailView.as_view()),
]
